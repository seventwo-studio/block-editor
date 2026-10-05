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
        deferred_conversion = command(resumed, 'convertBlock', caret, type='consumer-card')
        assert deferred_conversion['status'] == 'unavailable' and deferred_conversion['transaction'] is None
        assert success('modernSave', resumed) == unchanged_conversion
    column_session('soft-break', baseline)
    soft_caret = success('modernCaptureTextRange', 'soft-break', field=body_a, start=1, end=1)
    broken = command('soft-break', 'softBreak', soft_caret)
    assert broken['status'] == 'applied' and broken['document'] == fixture('unicode-soft-break')
    assert success('modernResolvePosition', 'soft-break', position=broken['focus'])['offset'] == 2
    assert command('soft-break', 'undo')['document'] == baseline
    assert command('soft-break', 'redo')['document'] == broken['document']
    # Retained cuts use independently written literal ABC expectations; these
    # supplement the committed fixture checks without modifying that catalog.
    assert all(name in capabilities['commands'] for name in ('splitBlock', 'mergeBlocks'))
    column_session('cut-a', baseline)
    column_session('cut-b', baseline)
    cut_target = success('modernCaptureTextRange', 'cut-a', field=body_a, start=1, end=1)
    tail_result = command('cut-a', 'splitBlock', cut_target, newBlockID='tail')
    tail_origin = tail_result['focus']['field']['node']
    expected_cut = json.loads(json.dumps(baseline))
    expected_cut['blocks'][0]['content'] = [dict(type='text', text='A')]
    expected_cut['blocks'].insert(1, dict(id='tail', type='paragraph', content=[dict(type='text', text='BC')]))
    assert tail_result['document'] == expected_cut and tail_result['status'] == 'applied'
    assert success('modernResolvePosition', 'cut-a', position=tail_result['focus'])['offset'] == 0
    assert success('modernReceive', 'cut-b', batch=success('modernChanges', 'cut-a'))['document'] == expected_cut
    tail_field = dict(node=tail_origin, name='content')
    edited_tail = success('modernCaptureTextRange', 'cut-b', field=tail_field, start=0, end=1)
    command('cut-b', 'replaceText', edited_tail, text='X')
    success('modernReceive', 'cut-a', batch=success('modernChanges', 'cut-b'))
    expected_undo = json.loads(json.dumps(baseline))
    expected_undo['blocks'][0]['content'] = [dict(type='text', text='AXC')]
    assert command('cut-a', 'undo')['document'] == expected_undo
    cut_saved = success('modernSave', 'cut-a')
    success('destroy', 'cut-a')
    success('restoreModern', 'cut-reopened', actorID='cut-a', snapshot=cut_saved)
    replayed = command('cut-reopened', 'redo')
    assert [block['id'] for block in replayed['document']['blocks']][:2] == ['A', 'tail']
    assert replayed['document']['blocks'][1]['content'] == [dict(type='text', text='XC')]
    merge_target = success('modernCaptureNodes', 'cut-reopened', nodes=[body_a['node'], tail_origin])
    merged = command('cut-reopened', 'mergeBlocks', merge_target)
    assert merged['document'] == expected_undo and merged['status'] == 'applied'
    assert success('modernResolvePosition', 'cut-reopened', position=merged['focus'])['offset'] == 1
    assert command('cut-reopened', 'undo')['document'] == replayed['document']
    # Explicit metadata incompatibility leaves both saved history and receipt intact.
    unchanged_cut = success('modernSave', 'cut-reopened')
    invalid_split = command('cut-reopened', 'splitBlock', cut_target, newBlockID='A')
    assert invalid_split['status'] == 'unavailable' and invalid_split['transaction'] is None
    assert success('modernSave', 'cut-reopened') == unchanged_cut
    # Schema conversions use literal expectations, independently of runtime output.
    column_session('schema-code-a', baseline)
    column_session('schema-code-b', baseline)
    schema_caret = success('modernCaptureTextRange', 'schema-code-a', field=body_a, start=2, end=2)
    old_replacement = success('modernCaptureTextRange', 'schema-code-b', field=body_a, start=1, end=2)
    code_result = command('schema-code-a', 'convertBlock', schema_caret, type='code')
    assert code_result['status'] == 'applied'
    assert code_result['document']['blocks'][0] == dict(id='A', type='code', code='ABC')
    assert success('modernResolvePosition', 'schema-code-a', position=schema_caret['start'])['address']['path'] == ['code']
    success('modernReceive', 'schema-code-b', batch=success('modernChanges', 'schema-code-a'))
    command('schema-code-b', 'replaceText', old_replacement, text='X')
    success('modernReceive', 'schema-code-a', batch=success('modernChanges', 'schema-code-b'))
    assert command('schema-code-a', 'undo')['document']['blocks'][0] == dict(id='A', type='paragraph', content=[dict(type='text', text='AXC')])
    schema_saved = success('modernSave', 'schema-code-a')
    success('restoreModern', 'schema-code-reopened', actorID='schema-code-a', snapshot=schema_saved)
    assert command('schema-code-reopened', 'redo')['document']['blocks'][0] == dict(id='A', type='code', code='AXC')
    assert success('modernResolvePosition', 'schema-code-reopened', position=schema_caret['start'])['offset'] == 2
    column_session('schema-list-a', baseline)
    column_session('schema-list-b', baseline)
    list_caret = success('modernCaptureTextRange', 'schema-list-a', field=body_a, start=1, end=1)
    listed = command('schema-list-a', 'convertBlock', list_caret, type='list', style='todo')
    assert listed['document']['blocks'][0] == dict(id='A', type='list', style='todo', items=[dict(id='A-item', checked=False, content=[dict(type='text', text='ABC')])])
    item_origin = dict(inserted=dict(creation=dict(change=listed['transaction'], index=0), path=[]))
    item_field = dict(node=item_origin, name='content')
    success('modernReceive', 'schema-list-b', batch=success('modernChanges', 'schema-list-a'))
    item_cut = success('modernCaptureTextRange', 'schema-list-b', field=item_field, start=1, end=1)
    schema_cut = command('schema-list-b', 'splitBlock', item_cut, newBlockID='schema-tail')
    success('modernReceive', 'schema-list-a', batch=success('modernChanges', 'schema-list-b'))
    retired = command('schema-list-a', 'undo')['document']['blocks']
    assert retired[0] == dict(id='A', type='paragraph', content=[dict(type='text', text='A')])
    assert retired[1] == dict(id='schema-tail', type='paragraph', checked=False, content=[dict(type='text', text='BC')])
    assert success('modernResolvePosition', 'schema-list-a', position=item_cut['start'])['address']['identity'] == schema_cut['focus']['field']['node']
    list_saved = success('modernSave', 'schema-list-a')
    success('restoreModern', 'schema-list-reopened', actorID='schema-list-a', snapshot=list_saved)
    assert len(command('schema-list-reopened', 'redo')['document']['blocks'][0]['items']) == 2
    column_session('schema-empty', baseline)
    empty_caret = success('modernCaptureTextRange', 'schema-empty', field=body_a, start=0, end=0)
    empty_list = command('schema-empty', 'convertBlock', empty_caret, type='list', style='todo')
    empty_origin = dict(inserted=dict(creation=dict(change=empty_list['transaction'], index=0), path=[]))
    empty_field = dict(node=empty_origin, name='content')
    all_text = success('modernCaptureTextRange', 'schema-empty', field=empty_field, start=0, end=3)
    command('schema-empty', 'replaceText', all_text, text='')
    empty_enter = success('modernCaptureTextRange', 'schema-empty', field=empty_field, start=0, end=0)
    exited = command('schema-empty', 'splitBlock', empty_enter, newBlockID='unused')
    assert exited['document']['blocks'][0] == dict(id='A', type='paragraph', style='todo', checked=False, content=[])
    assert success('modernResolvePosition', 'schema-empty', position=exited['focus'])['offset'] == 0
    assert command('schema-empty', 'undo')['document']['blocks'][0] == dict(id='A', type='list', style='todo', items=[dict(id='A-item', checked=False, content=[])])
    assert command('schema-empty', 'redo')['document'] == exited['document']
    opaque_code_document = dict(baseline, blocks=[dict(id='A', type='code', code='ABC', content=dict(consumer='retain'))])
    column_session('schema-opaque', opaque_code_document)
    opaque_target = success('modernCaptureTextRange', 'schema-opaque', field=dict(node=body_a['node'], name='code'), start=0, end=0)
    opaque_saved = success('modernSave', 'schema-opaque')
    rejected_opaque = command('schema-opaque', 'convertBlock', opaque_target, type='list')
    assert rejected_opaque['status'] == 'unavailable' and rejected_opaque['transaction'] is None
    assert rejected_opaque['document'] == opaque_code_document
    assert success('modernSave', 'schema-opaque') == opaque_saved
    # Retired peer roles remain authorable through the native command envelope.
    retained_field = schema_cut['focus']['field']
    retained_range = success('modernCaptureTextRange', 'schema-list-a', field=retained_field, start=1, end=1)
    headed = command('schema-list-a', 'convertBlock', retained_range, type='heading', level=2)
    expected_heading = dict(id='schema-tail', type='heading', level=2, checked=False, content=[dict(type='text', text='BC')])
    assert headed['status'] == 'applied' and headed['document']['blocks'][1] == expected_heading
    assert success('modernReceive', 'schema-list-b', batch=success('modernChanges', 'schema-list-a'))['document'] == headed['document']
    role_saved = success('modernSave', 'schema-list-a')
    success('restoreModern', 'role-reopened', actorID='schema-list-a', snapshot=role_saved)
    assert command('role-reopened', 'undo')['document']['blocks'][1] == dict(id='schema-tail', type='paragraph', checked=False, content=[dict(type='text', text='BC')])
    assert command('role-reopened', 'redo')['document']['blocks'][1] == expected_heading
    # First/middle/last empty root exits use independently written literal plans.
    for index in range(3):
        items = [dict(id=f'i{i}', checked=(i == 0), content=[] if i == index else [dict(type='text', text=f'I{i}')]) for i in range(3)]
        list_block = dict(id='list', type='list', style='todo', consumer='keep', items=items)
        enter_document = dict(baseline, blocks=[list_block])
        handle = f'enter-{index}'
        column_session(handle, enter_document)
        empty_field = dict(node=dict(baseline=dict(blockID='list', path=['items', f'i{index}'])), name='content')
        target = success('modernCaptureTextRange', handle, field=empty_field, start=0, end=0)
        exited = command(handle, 'splitBlock', target, newBlockID='tail')
        paragraph = dict(id=f'i{index}', type='paragraph', checked=(index == 0), content=[])
        if index == 0:
            expected = [paragraph, dict(list_block, items=items[1:])]
        elif index == 1:
            expected = [dict(list_block, items=items[:1]), paragraph, dict(list_block, id='tail', items=items[2:])]
        else:
            expected = [dict(list_block, items=items[:2]), paragraph]
        assert exited['status'] == 'applied' and exited['document']['blocks'] == expected
        assert success('modernResolvePosition', handle, position=exited['focus'])['address']['identity'] == empty_field['node']
        saved = success('modernSave', handle)
        reopened = handle + '-reopened'
        success('restoreModern', reopened, actorID=handle, snapshot=saved)
        assert command(reopened, 'undo')['document'] == enter_document
        assert command(reopened, 'redo')['document']['blocks'] == expected
    # List-only multi-item hierarchy, scalar state and scoped moves use literal
    # expectations written independently of runtime output and accepted fixtures.
    list_items = [dict(id=name, content=[dict(type='text', text=name.upper())], checked=False, consumer='keep-' + name) for name in ('a', 'b', 'c')]
    list_document = dict(baseline, blocks=[dict(id='L', type='list', style='todo', consumer='root', items=list_items),
                                         dict(id='M', type='list', style='todo', items=[dict(id='m', content=[dict(type='text', text='M')], checked=False)])])
    column_session('list-a', list_document)
    column_session('list-b', list_document)
    origins = [dict(baseline=dict(blockID='L', path=['items', name])) for name in ('b', 'c')]
    list_field = dict(node=origins[0], name='content')
    selected = success('modernCaptureListNodes', 'list-a', nodes=origins)
    caret = success('modernPosition', 'list-a', field=list_field, offset=1)
    target = dict(selection=selected, caret=caret)
    indented = command('list-a', 'listStructure', target, action='indent')
    expected_indent = dict(list_document, blocks=[dict(list_document['blocks'][0], items=[dict(list_items[0], children=list_items[1:])]), list_document['blocks'][1]])
    assert indented['status'] == 'applied' and indented['document'] == expected_indent
    peer_range = success('modernCaptureTextRange', 'list-b', field=list_field, start=1, end=1)
    command('list-b', 'replaceText', peer_range, text='!')
    success('modernReceive', 'list-a', batch=success('modernChanges', 'list-b'))
    success('modernReceive', 'list-b', batch=success('modernChanges', 'list-a'))
    expected_peer_items = [list_items[0], dict(list_items[1], content=[dict(type='text', text='B!')]), list_items[2]]
    expected_restored = dict(list_document, blocks=[dict(list_document['blocks'][0], items=expected_peer_items), list_document['blocks'][1]])
    assert command('list-a', 'undo')['document'] == expected_restored
    boundary = success('modernCaptureListBoundary', 'list-a', collection=dict(owner=dict(baseline=dict(blockID='M', path=[])), field='items'),
                       after=dict(baseline=dict(blockID='M', path=['items', 'm'])))
    selected = success('modernCaptureListNodes', 'list-a', nodes=origins)
    moved = command('list-a', 'listStructure', dict(selection=selected, caret=caret, boundary=boundary), action='reorder')
    expected_moved = dict(list_document, blocks=[dict(list_document['blocks'][0], items=expected_peer_items[:1]),
                                               dict(list_document['blocks'][1], items=list_document['blocks'][1]['items'] + expected_peer_items[1:])])
    assert moved['status'] == 'applied' and moved['document'] == expected_moved
    resolved_caret = success('modernResolvePosition', 'list-a', position=caret)
    assert resolved_caret['address']['identity'] == origins[0] and resolved_caret['offset'] == 1
    moved_save = success('modernSave', 'list-a')
    success('restoreModern', 'list-reopened', actorID='list-a', snapshot=moved_save)
    assert command('list-reopened', 'undo')['document'] == expected_restored
    assert command('list-reopened', 'redo')['document'] == expected_moved
    selected = success('modernCaptureListNodes', 'list-reopened', nodes=origins)
    checks = command('list-reopened', 'listStructure', dict(selection=selected), action='setChecked', checked=True)
    expected_checked_items = [dict(item, checked=True) for item in expected_peer_items[1:]]
    expected_checked = dict(list_document, blocks=[expected_moved['blocks'][0], dict(list_document['blocks'][1], items=list_document['blocks'][1]['items'] + expected_checked_items)])
    assert checks['status'] == 'applied' and checks['document'] == expected_checked
    assert command('list-reopened', 'undo')['document'] == expected_moved
    assert command('list-reopened', 'redo')['document'] == expected_checked
    success('modernSetListPolicy', 'list-reopened', allowedListActions=['setChecked', 'reorder'])
    policy = success('modernCapabilities', 'list-reopened')
    assert policy['listActions'] == ['reorder', 'setChecked'] and 'listStructure' in policy['commands']
    denied = command('list-reopened', 'listStructure', dict(selection=selected), action='setStyle', style='ordered')
    assert denied['status'] == 'unavailable' and denied['reason'] == 'hostPolicy' and denied['transaction'] is None
    success('modernSetListPolicy', 'list-reopened', allowedListActions=None)
    styled = command('list-reopened', 'listStructure', dict(selection=selected), action='setStyle', style='ordered')
    assert styled['status'] == 'applied' and styled['document']['blocks'] == [expected_checked['blocks'][0], dict(expected_checked['blocks'][1], style='ordered')]
    assert command('list-reopened', 'undo')['document'] == expected_checked
    # Semantic defaults and links use independent literal documents and marks,
    # preserving captured atoms, peer text and author-local Undo/reopen.
    bold = dict(type='bold')
    green = dict(type='semantic-color', value='green')
    link = dict(type='link', href='https://example.com/path')
    inline_document = dict(baseline, blocks=[dict(id='A', type='paragraph', consumer=dict(color='custom'), content=[dict(type='text', text='ABC', marks=[bold])]),
                                            dict(id='B', type='paragraph', content=[])])
    column_session('ink-a', inline_document)
    column_session('ink-b', inline_document)
    origin_a = dict(baseline=dict(blockID='A', path=[]))
    origin_b = dict(baseline=dict(blockID='B', path=[]))
    inline_field = dict(node=origin_a, name='content')
    text_target = success('modernCaptureTextRange', 'ink-a', field=inline_field, start=3, end=0)
    selection = success('modernCaptureNodes', 'ink-a', nodes=[origin_a, origin_b])
    nodes_target = dict(nodes=selection)
    peer_target = success('modernCaptureTextRange', 'ink-b', field=inline_field, start=1, end=1)
    command('ink-b', 'replaceText', peer_target, text='peer')
    peer_nodes = success('modernCaptureNodes', 'ink-b', nodes=[origin_a])
    command('ink-b', 'setSemanticColor', dict(nodes=peer_nodes), kind='fill', role='amber')
    colored = command('ink-a', 'setSemanticColor', nodes_target, kind='ink', role='blue')
    assert colored['status'] == 'applied' and colored['selectionIntent']['nodes']
    success('modernReceive', 'ink-a', batch=success('modernChanges', 'ink-b'))
    success('modernReceive', 'ink-b', batch=success('modernChanges', 'ink-a'))
    peer_document = dict(inline_document, blocks=[dict(inline_document['blocks'][0], semanticBackground='amber', content=[dict(type='text', text='ApeerBC', marks=[bold])]), inline_document['blocks'][1]])
    expected_defaults = dict(inline_document, blocks=[dict(peer_document['blocks'][0], semanticColor='blue'), dict(inline_document['blocks'][1], semanticColor='blue')])
    saved = success('modernSave', 'ink-a')
    success('restoreModern', 'ink-reopen', actorID='ink-a', snapshot=saved)
    assert command('ink-reopen', 'undo')['document'] == peer_document
    assert command('ink-reopen', 'redo')['document'] == expected_defaults
    assert success('modernSemanticState', 'ink-reopen', target=nodes_target, kind='ink') == dict(role=dict(_0='blue'))
    assert success('modernSemanticState', 'ink-reopen', target=nodes_target, kind='fill') == dict(mixed={})
    rich = command('ink-reopen', 'setSemanticColor', dict(range=text_target), kind='ink', role='green')
    expected_rich = dict(expected_defaults, blocks=[dict(expected_defaults['blocks'][0], content=[dict(type='text', text='A', marks=[bold, green]), dict(type='text', text='peer', marks=[bold]), dict(type='text', text='BC', marks=[bold, green])]), expected_defaults['blocks'][1]])
    assert rich['document'] == expected_rich and rich['focus'] == text_target['end']
    full_range = success('modernCaptureTextRange', 'ink-reopen', field=inline_field, start=0, end=7)
    assert success('modernSemanticState', 'ink-reopen', target=dict(range=full_range), kind='ink') == dict(mixed={})
    linked = command('ink-reopen', 'setLink', text_target, href='https://example.com/path')
    expected_linked = dict(expected_defaults, blocks=[dict(expected_defaults['blocks'][0], content=[dict(type='text', text='A', marks=[bold, link, green]), dict(type='text', text='peer', marks=[bold]), dict(type='text', text='BC', marks=[bold, link, green])]), expected_defaults['blocks'][1]])
    assert linked['document'] == expected_linked and linked['focus'] == text_target['end']
    saved = success('modernSave', 'ink-reopen')
    assert command('ink-reopen', 'setLink', text_target, href='https://example.com/path')['status'] == 'noop'
    assert success('modernSave', 'ink-reopen') == saved
    reset = command('ink-reopen', 'setSemanticColor', dict(range=text_target), kind='ink', role=None)
    expected_reset = dict(expected_defaults, blocks=[dict(expected_defaults['blocks'][0], content=[dict(type='text', text='A', marks=[bold, link]), dict(type='text', text='peer', marks=[bold]), dict(type='text', text='BC', marks=[bold, link])]), expected_defaults['blocks'][1]])
    assert reset['document'] == expected_reset
    assert success('modernSemanticState', 'ink-reopen', target=dict(range=text_target), kind='ink') == dict(role=dict(_0='blue'))
    assert command('ink-reopen', 'undo')['document'] == expected_linked
    assert command('ink-reopen', 'undo')['document'] == expected_rich
    assert command('ink-reopen', 'redo')['document'] == expected_linked
    caret = success('modernCaptureTextRange', 'ink-reopen', field=inline_field, start=7, end=7)
    label = command('ink-reopen', 'setLink', caret, href='mailto:hello@example.com', label='😀 link')
    expected_label = dict(expected_defaults, blocks=[dict(expected_linked['blocks'][0], content=expected_linked['blocks'][0]['content'] + [dict(type='text', text='😀 link', marks=[bold, dict(type='link', href='mailto:hello@example.com'), green])]), expected_defaults['blocks'][1]])
    assert label['document'] == expected_label
    assert success('modernResolvePosition', 'ink-reopen', position=label['focus'])['offset'] == 14
    assert command('ink-reopen', 'undo')['document'] == expected_linked
    saved = success('modernSave', 'ink-reopen')
    for name, target, arguments in [('setLink', text_target, dict(href='javascript:alert(1)')),
                                    ('setSemanticColor', nodes_target, dict(kind='ink', role='custom'))]:
        denied = command('ink-reopen', name, target, **arguments)
        assert denied['status'] == 'unavailable' and denied['transaction'] is None
        assert success('modernSave', 'ink-reopen') == saved
    success('modernSetAuthoringPolicy', 'ink-reopen', allowedCommands=['setLink', 'undo', 'redo'])
    assert success('modernCapabilities', 'ink-reopen')['commands'] == ['setLink', 'undo', 'redo']
    denied = command('ink-reopen', 'setSemanticColor', nodes_target, kind='ink', role='red')
    assert denied['status'] == 'unavailable' and denied['reason'] == 'hostPolicy' and denied['document'] == expected_linked
    # A captured range follows suffix atoms into a peer-created field. State
    # uses the actual field's default, while marks cover both retained segments.
    column_session('cross-a', inline_document)
    column_session('cross-b', inline_document)
    cross_range = success('modernCaptureTextRange', 'cross-a', field=inline_field, start=3, end=0)
    split_range = success('modernCaptureTextRange', 'cross-b', field=inline_field, start=1, end=1)
    split = command('cross-b', 'splitBlock', split_range, newBlockID='tail')
    tail_nodes = success('modernCaptureNodes', 'cross-b', nodes=[split['focus']['field']['node']])
    command('cross-b', 'setSemanticColor', dict(nodes=tail_nodes), kind='ink', role='blue')
    success('modernReceive', 'cross-a', batch=success('modernChanges', 'cross-b'))
    assert success('modernSemanticState', 'cross-a', target=dict(range=cross_range), kind='ink') == dict(mixed={})
    expected_cross_peer = dict(inline_document, blocks=[dict(inline_document['blocks'][0], content=[dict(type='text', text='A', marks=[bold])]),
                                                     dict(id='tail', type='paragraph', semanticColor='blue', content=[dict(type='text', text='BC', marks=[bold])]), inline_document['blocks'][1]])
    command('cross-a', 'setSemanticColor', dict(range=cross_range), kind='ink', role='green')
    cross = command('cross-a', 'setLink', cross_range, href='https://example.com/path')
    expected_cross = dict(inline_document, blocks=[dict(expected_cross_peer['blocks'][0], content=[dict(type='text', text='A', marks=[bold, link, green])]),
                                                dict(expected_cross_peer['blocks'][1], content=[dict(type='text', text='BC', marks=[bold, link, green])]), inline_document['blocks'][1]])
    assert cross['document'] == expected_cross
    assert success('modernSemanticState', 'cross-a', target=dict(range=cross_range), kind='ink') == dict(role=dict(_0='green'))
    cross_save = success('modernSave', 'cross-a')
    success('restoreModern', 'cross-reopen', actorID='cross-a', snapshot=cross_save)
    command('cross-reopen', 'undo')
    assert command('cross-reopen', 'undo')['document'] == expected_cross_peer
    assert success('modernSemanticState', 'cross-reopen', target=dict(range=cross_range), kind='ink') == dict(mixed={})
    command('cross-reopen', 'redo')
    assert command('cross-reopen', 'redo')['document'] == expected_cross
    # ACC-12 has a separately authored full document, including exact reference
    # and opaque consumer fields. No expected document is captured from runtime.
    mixed, mixed_copy = fixture('mixed'), fixture('mixed-duplicated')
    column_session('copy-a', mixed)
    column_session('copy-b', mixed)
    def duplicate_command(handle, name, target=None, **arguments):
        return success('modernCommand', handle, request=dict(documentID=mixed['documentID'], epoch=epoch,
                       command=name, target=target, arguments=arguments))
    copy_nodes = success('modernCaptureNodes', 'copy-a', nodes=[origin_a])
    copy_boundary = success('modernCaptureBoundary', 'copy-a', collection=dict(field='blocks'), after=origin_a)
    copied = duplicate_command('copy-a', 'duplicate', dict(selection=copy_nodes, boundary=copy_boundary), newBlockIDs=['copy-A'])
    assert copied['status'] == 'applied' and copied['document'] == mixed_copy
    copy_origin = copied['selection']['nodes'][0]
    assert copied['selectionIntent']['nodes']['_0']['nodes'] == [copy_origin]
    assert copied['focus']['field'] == dict(node=copy_origin, name='content')
    assert success('modernResolvePosition', 'copy-a', position=copied['focus'])['offset'] == 0
    success('modernReceive', 'copy-b', batch=success('modernChanges', 'copy-a'))
    body = dict(node=origin_a, name='content')
    copy_peer_range = success('modernCaptureTextRange', 'copy-b', field=body, start=0, end=0)
    expected_copy_peer = json.loads(json.dumps(mixed_copy))
    expected_copy_peer['blocks'][0]['content'][0]['text'] = 'peer Bold '
    assert duplicate_command('copy-b', 'replaceText', copy_peer_range, text='peer ')['document'] == expected_copy_peer
    success('modernReceive', 'copy-a', batch=success('modernChanges', 'copy-b'))
    assert success('modernDocument', 'copy-a') == expected_copy_peer
    copy_save = success('modernSave', 'copy-a')
    success('restoreModern', 'copy-reopen', actorID='copy-a', snapshot=copy_save)
    expected_copy_undo = json.loads(json.dumps(mixed))
    expected_copy_undo['blocks'][0]['content'][0]['text'] = 'peer Bold '
    assert duplicate_command('copy-reopen', 'undo')['document'] == expected_copy_undo
    assert duplicate_command('copy-reopen', 'redo')['document'] == expected_copy_peer
    success('modernSetAuthoringPolicy', 'copy-reopen', allowedCommands=['replaceTitle'])
    copy_unchanged = success('modernSave', 'copy-reopen')
    assert duplicate_command('copy-reopen', 'duplicate', dict(selection=copy_nodes, boundary=copy_boundary), newBlockIDs=['policy-copy'])['status'] == 'unavailable'
    assert success('modernSave', 'copy-reopen') == copy_unchanged
    success('modernSetAuthoringPolicy', 'copy-reopen', allowedCommands=None)
    copy_unchanged = success('modernSave', 'copy-reopen')
    assert duplicate_command('copy-reopen', 'duplicate', dict(selection=copy_nodes, boundary=copy_boundary), newBlockIDs=['A'])['status'] == 'unavailable'
    assert success('modernSave', 'copy-reopen') == copy_unchanged

    # Inert providers exercise the accepted late-result switch without any
    # upload, URL fetch or replacement-document acknowledgment.
    column_session('async-origin', mixed)
    column_session('async-replacement', baseline)
    media_origin = dict(baseline=dict(blockID='media', path=[]))
    def async_command(handle, name, target=None, document=mixed, **arguments):
        return success('modernCommand', handle, request=dict(documentID=document['documentID'], epoch=epoch,
                       command=name, target=target, arguments=arguments))
    provider_result = dict(src='asset://fixture/completed', width=640, height=480)
    async_target = success('modernBeginAsyncBlock', 'async-origin', node=media_origin, requestID='fixture-provider')
    origin_save, replacement_save = success('modernSave', 'async-origin'), success('modernSave', 'async-replacement')
    switched = async_command('async-replacement', 'completeAsyncBlock', async_target, metadata=provider_result)
    assert switched['status'] == 'unavailable' and switched['retainedResult'] == provider_result
    assert switched['document'] == baseline and switched['transaction'] is None and switched['focus'] is None
    assert success('modernSave', 'async-replacement') == replacement_save
    assert success('modernSave', 'async-origin') == origin_save
    assert success('modernAsyncRequests', 'async-origin')[0]['status'] == 'pending'
    success('modernCancelAsyncBlock', 'async-origin', target=async_target)
    cancelled = async_command('async-origin', 'completeAsyncBlock', async_target, metadata=provider_result)
    assert cancelled['status'] == 'unavailable' and cancelled['document'] == mixed
    assert success('modernAsyncRequests', 'async-origin')[0]['status'] == 'cancelled'
    retry_target = success('modernBeginAsyncBlock', 'async-origin', node=media_origin, requestID='retry-provider')
    assert retry_target['generation'] > async_target['generation']
    success('modernSetAuthoringPolicy', 'async-origin', allowedCommands=['replaceTitle'])
    assert async_command('async-origin', 'completeAsyncBlock', retry_target, metadata=provider_result)['reason'] == 'hostPolicy'
    assert success('modernAsyncRequests', 'async-origin')[-1]['result'] == provider_result
    success('modernSetAuthoringPolicy', 'async-origin', allowedCommands=None)
    success('modernComposition', 'async-origin', active=True)
    assert async_command('async-origin', 'completeAsyncBlock', retry_target, metadata=provider_result)['reason'] == 'compositionActive'
    success('modernComposition', 'async-origin', active=False)
    completed_media = json.loads(json.dumps(mixed))
    next(block for block in completed_media['blocks'] if block['id'] == 'media').update(provider_result)
    completed = async_command('async-origin', 'completeAsyncBlock', retry_target, metadata=provider_result)
    assert completed['status'] == 'applied' and completed['document'] == completed_media
    assert all(completed[field] is None for field in ['focus', 'selection', 'focusIntent', 'selectionIntent', 'retainedResult'])
    shared_async = json.dumps(success('modernChanges', 'async-origin'))
    assert 'requestID' not in shared_async and 'generation' not in shared_async and 'retry-provider' not in shared_async
    async_saved = success('modernSave', 'async-origin')
    async_archive = success('modernExportAsyncRequests', 'async-origin')
    success('restoreModern', 'async-reopen', actorID='async-origin', snapshot=async_saved)
    success('modernRestoreAsyncRequests', 'async-reopen', archive=async_archive)
    assert success('modernSave', 'async-reopen') == async_saved
    assert async_command('async-reopen', 'undo')['document'] == mixed
    undo_saved = success('modernSave', 'async-reopen')
    assert async_command('async-reopen', 'completeAsyncBlock', retry_target, metadata=provider_result)['status'] == 'noop'
    assert success('modernSave', 'async-reopen') == undo_saved
    assert async_command('async-reopen', 'redo')['document'] == completed_media
    delete_target = success('modernBeginAsyncBlock', 'async-origin', node=media_origin, requestID='deleted-provider')
    media_selection = success('modernCaptureNodes', 'async-origin', nodes=[media_origin])
    deleted_media = json.loads(json.dumps(completed_media))
    deleted_media['blocks'] = [block for block in deleted_media['blocks'] if block['id'] != 'media']
    assert async_command('async-origin', 'delete', dict(nodes=media_selection, ranges=[]))['document'] == deleted_media
    deleted_save = success('modernSave', 'async-origin')
    assert async_command('async-origin', 'completeAsyncBlock', delete_target, metadata=provider_result)['status'] == 'unavailable'
    assert success('modernSave', 'async-origin') == deleted_save
    assert success('modernAsyncRequests', 'async-origin')[-1]['result'] == provider_result

    # File metadata is a protocol-7 schema; asset bytes and consumer state stay
    # with the host. Initial insertion and completion have independent history.
    column_session('async-file', baseline)
    file_boundary = success('modernCaptureBoundary', 'async-file', collection=dict(field='blocks'))
    pending_file = dict(id='file', type='file', src='asset://pending/file', name='Research notes.pdf',
                        consumer=dict(assetID='fixture-only', status='pending'))
    expected_pending_file = json.loads(json.dumps(baseline)); expected_pending_file['blocks'].insert(0, pending_file)
    inserted_file = async_command('async-file', 'insertBlock', file_boundary, document=baseline, block=pending_file)
    assert inserted_file['document'] == expected_pending_file
    file_origin = inserted_file['selection']['nodes'][0]
    file_target = success('modernBeginAsyncBlock', 'async-file', node=file_origin, requestID='file-provider')
    file_metadata = dict(src='asset://fixture/notes', name='研究😀.pdf', mimeType='application/pdf', size=240000)
    expected_file = json.loads(json.dumps(expected_pending_file)); expected_file['blocks'][0].update(file_metadata)
    assert async_command('async-file', 'completeAsyncBlock', file_target, document=baseline, metadata=file_metadata)['document'] == expected_file
    assert async_command('async-file', 'undo', document=baseline)['document'] == expected_pending_file
    assert async_command('async-file', 'undo', document=baseline)['document'] == baseline
    assert async_command('async-file', 'redo', document=baseline)['document'] == expected_pending_file
    assert async_command('async-file', 'redo', document=baseline)['document'] == expected_file
    file_save, file_archive = success('modernSave', 'async-file'), success('modernExportAsyncRequests', 'async-file')
    success('restoreModern', 'async-file-reopen', actorID='async-file', snapshot=file_save)
    success('modernRestoreAsyncRequests', 'async-file-reopen', archive=file_archive)
    assert success('modernSave', 'async-file-reopen') == file_save

    column_session('async-preview', baseline)
    preview_boundary = success('modernCaptureBoundary', 'async-preview', collection=dict(field='blocks'))
    pending_preview = dict(id='preview', type='embed', url='https://example.org/notes', title='Pending', consumer=dict(opaque='keep'))
    inserted_preview = async_command('async-preview', 'insertBlock', preview_boundary, document=baseline, block=pending_preview)
    preview_origin = inserted_preview['selection']['nodes'][0]
    preview_target = success('modernBeginAsyncBlock', 'async-preview', node=preview_origin, requestID='preview-provider')
    preview_metadata = dict(title='Local preview', description='Inert fixture provider', thumbnail='asset://fixture/thumbnail')
    expected_preview = json.loads(json.dumps(baseline)); expected_preview['blocks'].insert(0, dict(pending_preview, **preview_metadata))
    assert async_command('async-preview', 'completeAsyncBlock', preview_target, document=baseline, metadata=preview_metadata)['document'] == expected_preview
    error_target = success('modernBeginAsyncBlock', 'async-preview', node=preview_origin, requestID='failed-provider')
    success('modernFailAsyncBlock', 'async-preview', target=error_target, reason='Provider interrupted')
    preview_save, preview_archive = success('modernSave', 'async-preview'), success('modernExportAsyncRequests', 'async-preview')
    success('restoreModern', 'async-preview-reopen', actorID='async-preview', snapshot=preview_save)
    success('modernRestoreAsyncRequests', 'async-preview-reopen', archive=preview_archive)
    assert success('modernSave', 'async-preview-reopen') == preview_save
    assert success('modernAsyncRequests', 'async-preview-reopen')[-1]['status'] == 'failed'
    assert async_command('async-preview-reopen', 'completeAsyncBlock', error_target, document=baseline, metadata=preview_metadata)['status'] == 'unavailable'
    assert success('modernSave', 'async-preview-reopen') == preview_save
    success('modernCancelAsyncBlock', 'async-preview-reopen', target=error_target)
    success('modernForgetAsyncBlock', 'async-preview-reopen', target=error_target)
    assert len(success('modernAsyncRequests', 'async-preview-reopen')) == 1

    report = dict(runtime='native C ABI', library=str(library),
                  librarySHA256=hashlib.sha256(library.read_bytes()).hexdigest(),
                  verifiedResponses=responses, independentFixtureHashes=hashes,
                  literalScenarios=['ABC split retains BC atoms; peer replaces B with X; author Undo yields AXC; reopen/Redo retains XC; merge and Undo preserve peer text', 'ABC code conversion; captured peer replacement yields AXC through author Undo and reopen/Redo; list creation and peer cut survive conversion Undo as A and BC paragraphs; sole empty checklist Enter preserves root metadata and Undo; opaque content on code blocks rejects list conversion unchanged', 'Retired peer item converts to a heading with metadata/peer convergence and Undo/reopen; first/middle/last empty root Enter preserve identities and literal list partitions through Undo/reopen', 'Multi-item list indent retains opaque fields; peer B! text survives Undo; scoped reorder moves original items between lists with stable caret and Undo/reopen; multi-item checked state and containing-list style preserve content and policy', 'Captured async image/file/preview metadata: ACC-15 replacement document, cancellation/generation, local policy/composition, retained provider results, separate request export/reopen, no focus change, source deletion, duplicate provider delivery after author Undo and distinct file insertion/completion history', 'ACC-12 full mixed duplicate fixture; exact rich reference and opaque metadata, node selection/input focus, later original peer edit, author Undo/reopen and unchanged policy/fresh-label rejection', 'Independent block ink/fill defaults, mixed/inherited state, captured backward semantic/link marks, peer text, reset, explicit Unicode labeled insertion, policy, one author Undo/reopen, marks across both fields after a peer split and unchanged unsafe submissions'],
                  qualification='Title/appearance/checked text commands plus structural packet admission and inserted-field editing/reopen. Checked structural targets, node/text/insertion focus intents and atomic multi-node deletion/move are exercised. Compound creation/removal/resize, peer-child creation Undo/reopen and split author Undo use independent column fixtures. Same-content heading conversion with peer text, stable caret, author Undo/reopen and soft breaks use independent writing fixtures. Retained split/merge use separately authored literal expectations over the unchanged unicode fixture. Literal code/list schema conversion and sole empty list-item Enter checks cover retained aliases, peer edits/cuts, author Undo/reopen and caret offsets. Empty first/middle/last root Enter and retained peer paragraph-role conversion add literal native expectations with identity and Undo/reopen checks. List-only hierarchy, scoped reorder, checklist/style state, local action policy and retained peer text/history have literal native checks. Semantic defaults, mixed/inherited state, checked link marks and labeled insertion have literal native checks. Deep duplication uses the independent ACC-12 mixed document and literal peer/history/policy checks. Captured async image/file/preview metadata and local provider lifecycle have inert native checks; no provider work is restarted or request identity replicated. Clipboard, migration, full command/focus history and complete provider/host acceptance remain pending.')
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, indent=2) + '\n')
    print(f'Verified {responses} native C ABI responses against {len(hashes)} independent fixtures.')


if __name__ == '__main__':
    main()
