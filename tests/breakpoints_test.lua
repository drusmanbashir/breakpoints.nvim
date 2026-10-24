-- PURPOSE: refuses loss of standalone breakpoint intent, native change events, migration and F3 semantics.
-- G1 is a headless integration check; real keys and rendered colours belong to G2.
local function check(name, fn)
  local ok, err = pcall(fn)
  if not ok then print('FAIL G1 ' .. name .. ': ' .. tostring(err)); vim.cmd('cquit 1') end
  print('PASS G1 ' .. name)
end
local function eq(a, b) assert(vim.deep_equal(a, b), vim.inspect(a) .. ' ~= ' .. vim.inspect(b)) end
local root = assert(vim.env.BP_TEST_ROOT)
vim.opt.rtp:prepend(root)
vim.g.mapleader = '\\'
local area = vim.fn.stdpath('state') .. '/fixture'
vim.fn.mkdir(area, 'p')
local path = area .. '/sample.py'
vim.fn.writefile({'a = 1', 'b = 2', 'print(a + b)'}, path)
local notices = {}
vim.notify = function(text) notices[#notices + 1] = text end
local old = vim.fn.stdpath('state') .. '/dap-sidecar/python'
vim.fn.mkdir(old, 'p')
local fixture = { ['<no-project>'] = { [path] = {{id='copied',line=1}} } }
local failing = vim.env.BP_TEST_CASE == 'copy-failure'
local existing = vim.env.BP_TEST_CASE == 'existing'
if existing then
  local destination=vim.fn.stdpath('state')..'/breakpoints/python'
  vim.fn.mkdir(destination,'p'); fixture['<no-project>'][path][1].id='existing'
  vim.fn.writefile({vim.json.encode(fixture)},destination..'/breakpoints.json')
  fixture['<no-project>'][path][1].id='copied'
end
if failing then vim.fn.mkdir(old .. '/breakpoints.json')
else vim.fn.writefile({vim.json.encode(fixture)}, old .. '/breakpoints.json') end
local bp
check('standalone require', function() bp = require('breakpoints'); assert(not package.loaded.dap) end)
check(failing and 'copy failure one notice' or 'one-time copy under setup', function()
  bp.setup()
  if failing then
    eq(#notices, 1); assert(notices[1]:find('copy',1,true)); bp.setup(); eq(#notices,1)
  else
    eq(bp.get(path)[1].id, existing and 'existing' or 'copied')
    local file = vim.fn.stdpath('state') .. '/breakpoints/python/breakpoints.json'
    assert(vim.fn.filereadable(file) == 1)
    assert(vim.fn.filereadable(old .. '/breakpoints.json') == 1)
    vim.fn.writefile({'{}'}, old .. '/breakpoints.json')
    bp.setup(); eq(bp.get(path)[1].id,existing and 'existing' or 'copied')
  end
end)
if failing then vim.cmd('qa!'); return end
local events = {}
vim.api.nvim_create_autocmd('User',{pattern='BreakpointsChanged',callback=function(ev) events[#events+1] = ev.data end})
vim.cmd.edit(path)
local buf = vim.api.nvim_get_current_buf()
local function key(lhs) return assert(vim.fn.maparg(lhs,'n',false,true).callback)() end
check('F2 toggle and committed events',function()
  bp.clear(path); events={}
  vim.api.nvim_win_set_cursor(0,{2,0}); key('<F2>')
  eq(#bp.get(path),1); eq(events[#events].path,path); eq(events[#events].lines,bp.get(path))
  key('<F2>'); eq(#bp.get(path),0); eq(events[#events].lines,{})
end)
check('modified buffer stores immediately',function()
  vim.api.nvim_buf_set_lines(buf,0,0,false,{'# moved'})
  vim.api.nvim_win_set_cursor(0,{2,0}); key('<F2>')
  eq(bp.get(path)[1].line,2)
  local file=vim.fn.stdpath('state')..'/breakpoints/python/breakpoints.json'
  local saved=vim.json.decode(table.concat(vim.fn.readfile(file),'\n'))
  eq(saved['<no-project>'][path][1].line,2)
end)
check('save merge moved marks',function()
  local id=bp.get(path)[1].id
  vim.api.nvim_buf_set_lines(buf,0,0,false,{'# moved again'})
  vim.cmd.write()
  eq(bp.get(path)[1].id,id); eq(bp.get(path)[1].line,3)
end)
check('past EOF refusal and drop on read',function()
  local action, why=bp.toggle(path,99)
  eq(action,nil); eq(why,'No breakpoints past EOF')
  local shorter=area..'/shorter.py'
  vim.fn.writefile({'a=1','b=2','print(a+b)'},shorter); bp.toggle(shorter,3)
  vim.fn.writefile({'a=1'},shorter)
  local before=#notices; events={}; vim.cmd.edit(shorter)
  eq(#bp.get(shorter),0); eq(#notices,before+1)
  eq(events[#events],{path=shorter,lines={}})
  vim.cmd.edit(path)
  bp.clear(path)

end)
check('F3 create remove convert and combo refusal',function()
  local input=vim.ui.input
  vim.ui.input=function(opts,cb) eq(opts.prompt,'Log message: '); cb('value {a}') end
  vim.api.nvim_win_set_cursor(0,{1,0}); key('<F3>'); eq(bp.get(path)[1].log_message,'value {a}')
  key('<F3>'); eq(#bp.get(path),0)
  key('<F2>'); local id=bp.get(path)[1].id; key('<F3>'); eq(bp.get(path)[1].id,id); eq(bp.get(path)[1].log_message,'value {a}')
  key('<F3>'); key('<F2>'); id=bp.get(path)[1].id; assert(bp.update(id,{remove_once=true})); key('<F3>')
  eq(bp.get(path)[1].remove_once,true); eq(bp.get(path)[1].log_message,nil)
  bp.clear(path)
  for _,answer in ipairs({'',false}) do vim.ui.input=function(_,cb) cb(answer or nil) end; key('<F3>'); eq(#bp.get(path),0) end
  vim.ui.input=input
end)
check('clear both kinds and linked highlights',function()
  bp.toggle(path,1); bp.toggle(path,2,{log_message='a'})
  local marks=require('breakpoints.breakpoints.bp_marks').list(buf)
  eq(marks[1].text,'●'); eq(marks[2].text,'●')
  eq(marks[1].hl,'BreakpointsBreakpoint'); eq(marks[2].hl,'BreakpointsLogPoint')
  for name,target in pairs({BreakpointsBreakpoint='DiagnosticError',BreakpointsLogPoint='Function',BreakpointsMuted='Comment'}) do eq(vim.api.nvim_get_hl(0,{name=name}).link,target) end
  key('<S-F2>'); eq(#bp.get(path),0)
  bp.toggle(path,1); key('<F14>'); eq(#bp.get(path),0)
end)
check('public removal repaints',function()
  bp.toggle(path,1); local id=bp.get(path)[1].id; assert(bp.remove_by_id(id))
  eq(require('breakpoints.breakpoints.bp_marks').list(buf),{})
end)
check('failed mutation publishes committed recovery',function()
  bp.toggle(path,1); local saved=bp.get(path)
  local file=require('breakpoints.storage.bp_file'); local persist=file.persist
  events={}; local before=#notices
  file.persist=function() return nil,'injected write failure' end
  vim.api.nvim_win_set_cursor(0,{2,0}); key('<F2>')
  file.persist=persist
  eq(bp.get(path),saved); eq(events,{{path=path,lines=saved}}); eq(#notices,before+1)
  eq(#require('breakpoints.breakpoints.bp_marks').list(buf),1)
  bp.clear(path)
end)
check('failed prune keeps committed event payload',function()
  local gone=area..'/gone.py'; vim.fn.writefile({'a=1'},gone); bp.toggle(gone,1)
  local saved=bp.get(gone); vim.fn.delete(gone)
  local file=require('breakpoints.storage.bp_file'); local persist=file.persist
  events={}; file.persist=function() return nil,'injected prune failure' end
  bp.get(path)
  file.persist=persist
  eq(events,{{path=gone,lines=saved}})
  bp.get(path); eq(events[#events],{path=gone,lines={}})
end)
check('rename moves IDs and events',function()
  bp.toggle(path,1); local id=bp.get(path)[1].id
  local renamed=area..'/renamed.py'; events={}
  vim.api.nvim_buf_set_name(buf,renamed)
  eq(#bp.get(path),0); eq(bp.get(renamed)[1].id,id)
  eq(events[1],{path=path,lines={}}); eq(events[2].path,renamed)
  vim.cmd.write(); path=renamed
end)
check('rename occupied and other space refusal',function()
  local occupied=area..'/occupied.py'; vim.fn.writefile({'x=1'},occupied); bp.toggle(occupied,1)
  vim.api.nvim_buf_set_name(buf,occupied); eq(#bp.get(path),1); eq(#bp.get(occupied),1)
  vim.api.nvim_buf_set_name(buf,path)
  local git=area..'/project'; vim.fn.mkdir(git,'p'); vim.fn.system({'git','init',git})
  vim.api.nvim_buf_set_name(buf,git..'/other.py'); eq(#bp.get(path),1); eq(#bp.get(git..'/other.py'),0)
  vim.api.nvim_buf_set_name(buf,path)
end)
check('properties box and standalone no breakpoint notice',function()
  vim.api.nvim_win_set_cursor(0,{1,0}); key('\\dT')
  assert(vim.api.nvim_win_get_config(0).relative~=''); eq(vim.api.nvim_buf_line_count(0),4)
  vim.fn.maparg('<Esc>','n',false,true).callback()
  vim.api.nvim_win_set_cursor(0,{2,0}); key('\\dT'); eq(notices[#notices],'No breakpoint on this line')
end)
check('folder language independent of sidecar',function()
  eq(require('breakpoints.storage.bp_language').of_path(area..'/hello.c'),'cpp')
  for name in pairs(package.loaded) do assert(not name:match('^dap'),name) end
end)
check('attached validation uses folder language and host style',function()
  local cfile=area..'/hello.c'; vim.fn.writefile({'int x;'},cfile)
  local focused=0
  bp.attach({
    validate=function(language,props) eq(language,'cpp'); if props.condition=='refuse' then return 'host refusal' end end,
    style=function(source) if source==cfile then return {text='●',hl='BreakpointsMuted',note='host note'} end end,
    focus_list=function() focused=focused+1 end,
  })
  vim.cmd.edit(cfile); bp.toggle(cfile,1); local id=bp.get(cfile)[1].id
  local value,why=bp.update(id,{condition='refuse'}); eq(value,nil); eq(why,'host refusal')
  assert(bp.update(id,{condition='x>1'})); bp.redraw()
  eq(require('breakpoints.breakpoints.bp_marks').list(vim.api.nvim_get_current_buf())[1].hl,'BreakpointsMuted')
  assert(vim.tbl_contains(bp.describe(vim.api.nvim_get_current_buf(),1),'host note'))
  vim.api.nvim_win_set_cursor(0,{1,0}); key('\\dT')
  key('\\dT'); eq(focused,1)
end)
print('PASS G1 breakpoints_test')
vim.cmd('qa!')
