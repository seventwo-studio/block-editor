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
    assert all(name in capabilities['commands'] for name in ('createColumns', 'removeColumns', 'resizeColumns'))
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
    unsupported = command('resumed', 'indent')
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
    # Checked structural request/result scenarios follow below.
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
    assert all(name in capabilities['commands'] for name in ('insertBlock', 'move', 'delete'))
    # Checked structural results use the independent nested move snapshots.
    nested = fixture('nested')
    nested_moved = fixture('nested-moved')
    success('createModern', 'nested', actorID='nested', documentID=nested['documentID'],
            epoch=epoch, collaborationVersion=7, document=nested)
    origin_a = {'baseline': {'blockID': 'A', 'path': []}}
    selected = success('modernCaptureNodes', 'nested', nodes=[origin_a])
    root_boundary = success('modernCaptureBoundary', 'nested', collection={'field': 'blocks'})
    def structural_command(name, target=None, **arguments):
        return success('modernCommand', 'nested', request=dict(documentID=nested['documentID'], epoch=epoch,
                       command=name, target=target, arguments=arguments))
    moved = structural_command('move', dict(selection=selected, boundary=root_boundary))
    assert moved['status'] == 'applied' and moved['document'] == nested_moved
    assert moved['selection']['nodes'] == [origin_a]
    assert moved['focusIntent']['nodes']['_0'] == moved['selection']
    assert structural_command('undo')['document'] == nested
    assert structural_command('redo')['document'] == nested_moved
    captured = success('modernCaptureBoundary', 'nested', collection={'field': 'blocks'})
    inserted = structural_command('insertBlock', captured, block=dict(id='checked', type='paragraph',
                                   content=[dict(type='text', text='Writing', marks=[])]))
    assert inserted['status'] == 'applied' and inserted['focusIntent']['text']['_0'] == inserted['focus']
    assert inserted['selectionIntent']['text']['_0'] == inserted['selection']
    inserted_id = {'inserted': {'creation': {'change': inserted['transaction'], 'index': 0}, 'path': []}}
    ordered = [inserted_id, origin_a] + [{'baseline': {'blockID': label, 'path': []}} for label in ('toggle', 'list')]
    all_nodes = success('modernCaptureNodes', 'nested', nodes=ordered)
    removed = structural_command('delete', dict(nodes=all_nodes, ranges=[]))
    assert removed['status'] == 'applied' and removed['document']['blocks'] == []
    assert removed['document']['title'] == nested['title']
    assert removed['focus'] is None and removed['selection'] is None
    insertion = removed['focusIntent']['insertion']['_0']
    assert insertion['collection'] == {'field': 'blocks'}
    assert structural_command('undo')['document'] == inserted['document']
    assert structural_command('redo')['document'] == removed['document']
    resumed_body = structural_command('insertBlock', insertion, block=dict(id='resumed', type='paragraph',
                                      content=[dict(type='text', text='Resume', marks=[])]))
    assert [block['id'] for block in resumed_body['document']['blocks']] == ['resumed']
    # Stale targets cannot select another origin; malformed nested targets leave receipts intact.
    saved_structural = success('modernSave', 'nested')
    stale = call('modernCommand', 'nested', request=dict(documentID=nested['documentID'], epoch=epoch,
                 command='delete', target=dict(nodes=all_nodes, ranges=[]), arguments={}))
    assert stale['ok'] is False
    assert success('modernSave', 'nested') == saved_structural
    unsafe_block = dict(id='unsafe', type='paragraph', content=[dict(type='text', text='Bad',
                        marks=[dict(type='link', href='javascript:bad')])])
    rejected = call('modernCommand', 'nested', request=dict(documentID=nested['documentID'], epoch=epoch,
                    command='insertBlock', target=root_boundary, arguments=dict(block=unsafe_block)))
    assert rejected['ok'] is False
    assert success('modernSave', 'nested') == saved_structural
    # Compound column commands compare original accepted snapshots through the C ABI.
    before_columns, created_columns = fixture('before-columns'), fixture('columns-created')
    create_peer, create_undone_peer = fixture('columns-create-peer'), fixture('columns-create-undone-peer')
    layout = json.loads(json.dumps(created_columns['blocks'][0]))
    for column in layout['columns']:
        column['children'] = []
    def column_session(handle, document):
        success('createModern', handle, actorID=handle, documentID=document['documentID'], epoch=epoch,
                collaborationVersion=7, document=document)
    def column_command(handle, name, target=None, **arguments):
        return success('modernCommand', handle, request=dict(documentID=before_columns['documentID'], epoch=epoch,
                       command=name, target=target, arguments=arguments))
    column_session('columns-a', before_columns)
    selected = success('modernCaptureNodes', 'columns-a', nodes=[{'baseline': {'blockID': label, 'path': []}} for label in ('A', 'B')])
    grouped = column_command('columns-a', 'createColumns', dict(selection=selected), layout=layout)
    assert grouped['status'] == 'applied' and grouped['document'] == created_columns
    layout_origin = grouped['selection']['nodes'][0]
    assert column_command('columns-a', 'undo')['document'] == before_columns
    assert column_command('columns-a', 'redo')['document'] == created_columns
    column_session('columns-b', before_columns)
    success('modernReceive', 'columns-b', batch=success('modernChanges', 'columns-a'))
    second_origin = json.loads(json.dumps(layout_origin))
    second_origin['inserted']['path'] = ['columns', 'second-column']
    peer_boundary = success('modernCaptureBoundary', 'columns-b', collection=dict(owner=second_origin, field='children'))
    peer_block = create_peer['blocks'][0]['columns'][1]['children'][0]
    assert column_command('columns-b', 'insertBlock', peer_boundary, block=peer_block)['document'] == create_peer
    success('modernReceive', 'columns-a', batch=success('modernChanges', 'columns-b'))
    assert column_command('columns-a', 'undo')['document'] == create_undone_peer
    saved_columns = success('modernSave', 'columns-a')
    success('restoreModern', 'columns-reopened', actorID='columns-a', snapshot=saved_columns)
    assert column_command('columns-reopened', 'redo')['document'] == create_peer
    column_session('columns-remove', fixture('columns-3000'))
    baseline_layout = dict(baseline=dict(blockID='layout', path=[]))
    removed = column_command('columns-remove', 'removeColumns', dict(layout=baseline_layout))
    assert removed['document'] == fixture('columns-flattened') and removed['status'] == 'applied'
    assert len(removed['selection']['nodes']) == 3
    assert column_command('columns-remove', 'undo')['document'] == fixture('columns-3000')
    column_session('split-a', fixture('columns-5000'))
    column_session('split-b', fixture('columns-5000'))
    assert column_command('split-a', 'resizeColumns', dict(layout=baseline_layout), splitBasisPoints=6000)['document'] == fixture('columns-split-a')
    assert column_command('split-b', 'resizeColumns', dict(layout=baseline_layout), splitBasisPoints=4000)['document'] == fixture('columns-split-b')
    success('modernReceive', 'split-a', batch=success('modernChanges', 'split-b'))
    success('modernReceive', 'split-b', batch=success('modernChanges', 'split-a'))
    assert column_command('split-b', 'undo')['document'] == fixture('columns-split-a')
    success('modernReceive', 'split-a', batch=success('modernChanges', 'split-b'))
    assert column_command('split-a', 'undo')['document'] == fixture('columns-5000')
    unchanged_split = success('modernSave', 'split-a')
    for invalid in (999, 9001, 5000.5):
        rejected = column_command('split-a', 'resizeColumns', dict(layout=baseline_layout), splitBasisPoints=invalid)
        assert rejected['status'] == 'unavailable' and rejected['transaction'] is None
        assert success('modernSave', 'split-a') == unchanged_split
    # Creation inside an existing column rejects without receipt/history changes.
    nested_boundary = success('modernCaptureBoundary', 'columns-reopened', collection=dict(owner=second_origin, field='children'))
    saved_before_nested = success('modernSave', 'columns-reopened')
    denied_nested = column_command('columns-reopened', 'createColumns', dict(boundary=nested_boundary), layout=layout)
    assert denied_nested['status'] == 'unavailable'
    assert success('modernSave', 'columns-reopened') == saved_before_nested
    column_session('empty-columns', before_columns)
    empty_boundary = success('modernCaptureBoundary', 'empty-columns', collection=dict(field='blocks'), after=dict(baseline=dict(blockID='B', path=[])))
    empty_created = column_command('empty-columns', 'createColumns', dict(boundary=empty_boundary), layout=layout)
    empty_removed = column_command('empty-columns', 'removeColumns', dict(layout=empty_created['selection']['nodes'][0]))
    assert empty_removed['document'] == before_columns and empty_removed['selection'] is None
    resumed_boundary = empty_removed['focusIntent']['insertion']['_0']
    empty_resumed = column_command('empty-columns', 'insertBlock', resumed_boundary, block=dict(id='Resume', type='paragraph', content=[dict(type='text', text='Write here')]))
    assert [block['id'] for block in empty_resumed['document']['blocks']] == ['A', 'B', 'Resume', 'C', 'E']
    # Same-content conversion retains an observed caret while peer text arrives.
    assert all(name in capabilities['commands'] for name in ('convertBlock', 'softBreak'))
    body_a = dict(node=dict(baseline=dict(blockID='A', path=[])), name='content')
    expected_heading, expected_suffix = fixture('unicode-peer-heading'), fixture('unicode-peer-suffix')
    for peer_first in (False, True):
        author, peer = ('convert-first-a', 'convert-first-b') if peer_first else ('convert-last-a', 'convert-last-b')
        column_session(author, baseline)
        column_session(peer, baseline)
        caret = success('modernCaptureTextRange', author, field=body_a, start=3, end=3)
        peer_caret = success('modernCaptureTextRange', peer, field=body_a, start=3, end=3)
        command(peer, 'replaceText', peer_caret, text=' remote')
        peer_packet = success('modernChanges', peer)
        if peer_first:
            success('modernReceive', author, batch=peer_packet)
        converted = command(author, 'convertBlock', caret, type='heading', level=2)
        assert converted['status'] == 'applied' and converted['focus'] == caret['start']
        assert success('modernReceive', author, batch=peer_packet)['document'] == expected_heading
        assert success('modernReceive', peer, batch=success('modernChanges', author))['document'] == expected_heading
        assert success('modernResolvePosition', author, position=converted['focus'])['offset'] == 3
        assert command(author, 'undo')['document'] == expected_suffix
        saved_conversion = success('modernSave', author)
        success('destroy', author)
        resumed = author + '-reopened'
        assert success('restoreModern', resumed, actorID=author, snapshot=saved_conversion)['document'] == expected_suffix
        assert command(resumed, 'redo')['document'] == expected_heading
        assert success('modernResolvePosition', resumed, position=converted['focus'])['offset'] == 3
        unchanged_conversion = success('modernSave', resumed)
        invalid_conversion = command(resumed, 'convertBlock', caret, type='heading', level=4)
        assert invalid_conversion['status'] == 'unavailable' and invalid_conversion['transaction'] is None
        assert success('modernSave', resumed) == unchanged_conversion
        deferred_conversion = command(resumed, 'convertBlock', caret, type='code')
        assert deferred_conversion['status'] == 'unavailable' and deferred_conversion['transaction'] is None
        assert success('modernSave', resumed) == unchanged_conversion
    column_session('soft-break', baseline)
    soft_caret = success('modernCaptureTextRange', 'soft-break', field=body_a, start=1, end=1)
    broken = command('soft-break', 'softBreak', soft_caret)
    assert broken['status'] == 'applied' and broken['document'] == fixture('unicode-soft-break')
    assert success('modernResolvePosition', 'soft-break', position=broken['focus'])['offset'] == 2
    assert command('soft-break', 'undo')['document'] == baseline
    assert command('soft-break', 'redo')['document'] == broken['document']
    report = dict(runtime='native C ABI', library=str(library),
                  librarySHA256=hashlib.sha256(library.read_bytes()).hexdigest(),
                  verifiedResponses=responses, independentFixtureHashes=hashes,
                  qualification='Title/appearance/checked text commands plus structural packet admission and inserted-field editing/reopen. Checked structural targets, node/text/insertion focus intents and atomic multi-node deletion/move are exercised. Compound creation/removal/resize, peer-child creation Undo/reopen and split author Undo use independent column fixtures. Same-content heading conversion with peer text, stable caret, author Undo/reopen and soft breaks use independent writing fixtures. Schema-changing conversion, split/merge, list structure, clipboard, migration and full host acceptance remain pending.')
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, indent=2) + '\n')
    print(f'Verified {responses} native C ABI responses against {len(hashes)} independent fixtures.')


if __name__ == '__main__':
    main()
