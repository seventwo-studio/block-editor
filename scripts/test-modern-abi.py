#!/usr/bin/env python3
"""Exercise modern JSON endpoints through the compiled C ABI and independent fixtures."""
import argparse
import ctypes
import hashlib
import json
from pathlib import Path


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--library', required=True, type=Path)
    parser.add_argument('--output', required=True, type=Path)
    args = parser.parse_args()
    library = args.library.resolve()
    runtime = ctypes.CDLL(str(library))
    pointer = ctypes.POINTER(ctypes.c_uint8)
    runtime.block_editor_alloc.argtypes = [ctypes.c_int32]
    runtime.block_editor_alloc.restype = pointer
    runtime.block_editor_call.argtypes = [pointer, ctypes.c_int32]
    runtime.block_editor_call.restype = pointer
    runtime.block_editor_free.argtypes = [pointer]
    runtime.block_editor_free.restype = None
    root = Path(__file__).resolve().parents[1]
    fixtures = root / 'docs/acceptance/modern-editor/documents'
    hashes = {}
    responses = 0

    def fixture(name):
        path = fixtures / (name + '.json')
        data = path.read_bytes()
        hashes[str(path.relative_to(root))] = hashlib.sha256(data).hexdigest()
        return json.loads(data)

    def raw_call(data):
        nonlocal responses
        source = runtime.block_editor_alloc(len(data))
        assert source, 'ABI input allocation failed'
        output = None
        try:
            ctypes.memmove(source, data, len(data))
            output = runtime.block_editor_call(source, len(data))
            assert output, 'ABI returned no response'
            result = json.loads(ctypes.string_at(output))
            responses += 1
            return result
        finally:
            if output:
                runtime.block_editor_free(output)
            runtime.block_editor_free(source)

    def call(command, handle='a', **fields):
        fields.update(command=command, session=handle)
        return raw_call(json.dumps(fields, ensure_ascii=False, separators=(',', ':')).encode())

    def success(command, handle='a', **fields):
        result = call(command, handle, **fields)
        assert result.get('ok') is True, result
        return result['value']

    baseline = fixture('unicode')
    expected_both = fixture('unicode-title-both')
    expected_size = fixture('unicode-title-size-both')
    expected_peer = fixture('unicode-title-peer')
    document_id = baseline['documentID']
    epoch = 'modern-abi-1'
    for actor in ('a', 'b'):
        created = success('createModern', actor, actorID=actor, documentID=document_id,
                          epoch=epoch, collaborationVersion=7, document=baseline)
        assert created['document'] == baseline and created['canUndo'] is False
    capabilities = success('modernCapabilities')
    assert capabilities['protocolVersion'] == 7 and capabilities['formatVersion'] == 1
    assert capabilities['cutoverToModern'] is False
    assert 'createColumns' not in capabilities['commands']
    title = {'node': {'document': {'documentID': document_id}}, 'name': 'title'}
    document_origin = title['node']

    def capture(actor, start, end):
        return success('modernCaptureTextRange', actor, field=title, start=start, end=end)

    def command(actor, name, target=None, **arguments):
        result = success('modernCommand', actor, request=dict(documentID=document_id, epoch=epoch,
                         command=name, target=target, arguments=arguments))
        assert result['status'] in ('applied', 'noop', 'unavailable', 'recoveryRequired'), result
        return result

    first = command('a', 'replaceTitle', capture('a', 0, 0), text='Studio ')
    assert first['status'] == 'applied' and first['transaction']['actor'] == 'a'
    assert first['focus']['field'] == title
    end = len(baseline['title'].encode('utf-16-le')) // 2
    command('b', 'replaceTitle', capture('b', end, end), text=' 2026')
    command('b', 'setAppearance', document_origin, field='pageWidth', value='wide')
    first_packet = success('modernChanges', 'a')
    second_packet = success('modernChanges', 'b')
    assert success('modernReceive', 'a', batch=second_packet)['document'] == expected_both
    assert success('modernReceive', 'b', batch=first_packet)['document'] == expected_both
    assert command('a', 'setAppearance', document_origin, field='fontSize', value='large')['document'] == expected_size
    command('a', 'undo')
    assert command('a', 'undo')['document'] == expected_peer
    saved = success('modernSave', 'a')
    success('destroy', 'a')  # Stop this author before resuming its saved actor/history.
    restored = success('restoreModern', 'resumed', actorID='a', snapshot=saved)
    assert restored['canRedo'] is True and restored['document'] == expected_peer
    command('resumed', 'redo')
    assert command('resumed', 'redo')['document'] == expected_size
    no_change = command('resumed', 'setAppearance', document_origin, field='fontSize', value='large')
    assert no_change['status'] == 'noop' and no_change['transaction'] is None
    unsupported = command('resumed', 'createColumns')
    assert unsupported['status'] == 'unavailable' and unsupported['document'] == expected_size
    assert success('modernReceive', 'b', batch=success('modernChanges', 'resumed'))['document'] == expected_size
    assert call('create', 'legacy-seven', actorID='old', documentID=document_id,
                collaborationVersion=7, blocks=[])['ok'] is False
    assert call('createModern', 'wrong-version', actorID='bad', documentID=document_id,
                epoch=epoch, collaborationVersion=6, document=baseline)['ok'] is False
    duplicate = b'{"command":"modernCapabilities","command":"modernCapabilities"}'
    assert raw_call(duplicate)['ok'] is False
    lossy_document = json.dumps(baseline, ensure_ascii=False)[:-1] + ',"opaque":9007199254740993}'
    malformed = ('{"command":"createModern","session":"lossy","actorID":"lossy",'
                 '"collaborationVersion":7,"documentID":' + json.dumps(document_id) + ',"epoch":'
                 + json.dumps(epoch) + ',"document":' + lossy_document + '}').encode()
    assert raw_call(malformed)['ok'] is False
    # Failed creation must leave the handle available for an admitted document.
    assert success('createModern', 'lossy', actorID='lossy', documentID=document_id,
                   epoch=epoch, collaborationVersion=7, document=baseline)['document'] == baseline
    # Receive a real protocol-7 structural birth through the same compiled ABI.
    # Local structural command/focus results are deliberately not advertised yet.
    created_id = {'counter': 1, 'actor': 'structural-peer'}
    element = {'change': created_id, 'index': 0}
    identity = {'inserted': {'creation': element, 'path': []}}
    paragraph = {'id': 'abi-inserted', 'type': 'paragraph',
                 'content': [{'type': 'text', 'text': 'seed', 'marks': []}]}
    structural = dict(version=7, documentID=document_id, epoch=epoch, baseline=baseline,
                      changes=[dict(id=created_id, observed=[], body={'edit': {'_0': [
                          {'structure': {'_0': {'insertNode': dict(value=paragraph, identity=identity,
                              collection={'field': 'blocks'}, placement=element)}}}]}})])
    assert success('createModern', 'structure', actorID='structure', documentID=document_id,
                   epoch=epoch, collaborationVersion=7, document=baseline)['document'] == baseline
    expected_structural = dict(baseline, blocks=[paragraph] + baseline['blocks'])
    assert success('modernReceive', 'structure', batch=structural)['document'] == expected_structural
    body_field = dict(node=identity, name='content')
    body_target = success('modernCaptureTextRange', 'structure', field=body_field, start=4, end=4)
    edited = command('structure', 'replaceText', body_target, text=' peer')
    assert edited['status'] == 'applied' and edited['document']['blocks'][0]['content'][0]['text'] == 'seed peer'
    assert command('structure', 'undo')['document'] == expected_structural
    assert command('structure', 'redo')['document'] == edited['document']
    structural_saved = success('modernSave', 'structure')
    success('destroy', 'structure')
    structural_restored = success('restoreModern', 'structure-resumed', actorID='structure', snapshot=structural_saved)
    assert structural_restored['document'] == edited['document'] and structural_restored['canUndo'] is True
    assert 'insertBlock' not in capabilities['commands'] and 'move' not in capabilities['commands']
    report = dict(runtime='native C ABI', library=str(library),
                  librarySHA256=hashlib.sha256(library.read_bytes()).hexdigest(),
                  verifiedResponses=responses, independentFixtureHashes=hashes,
                  qualification='Title/appearance/checked text commands plus structural packet admission and inserted-field editing/reopen. Local structural command/focus results, compound layout commands, migration and full host acceptance remain pending.')
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, indent=2) + '\n')
    print(f'Verified {responses} native C ABI responses against 4 independent fixtures.')


if __name__ == '__main__':
    main()
