" Settings
let s:cmake_command = get(g:, 'cmake_command', 'cmake')
let s:jq_command = get(g:, 'jq_command', 'jq')
let s:cmake_build_command = get(g:, 'cmake_command', s:cmake_command . ' --build %s --target %s')
let s:cmake_build_dirs = get(g:, 'cmake_build_dirs', [ '.', 'build' ])
let s:default_target = get(g:, 'default_target', 'all')
let s:idle_statusline = get(g:, 'idle_statusline', 'Project: %p | Target: %t')
let s:action_statusline = get(g:, 'action_statusline', 'Action: %a: %min %cur %max')

" Global variables
let s:debug = v:false

let s:build_dirs = {} " Dummy values; used as a set
let s:cmake_servers = {}


" Message handling {{{
let s:handlers = {}

function! s:handlers.hello(message)
    echom "kek: " string(a:message['supportedProtocolVersions'])
    let s:protocol = a:message['supportedProtocolVersions'][0]
    call SendHandShake()
endfunction

function! s:handlers.reply(message)
    if a:message['inReplyTo'] == 'handshake'
        echom "handshake done, configuring"
        call SendConfigure()
    elseif a:message['inReplyTo'] == 'configure'
        echom "configure done, computing"
        call SendCompute()
    elseif a:message['inReplyTo'] == 'compute'
        echom "compute done"
    elseif a:message['inReplyTo'] == 'codemodel'
        call ParseCodeModel(a:message)
    else
        echom "Reply! inReplyTo: " a:message['inReplyTo']
    endif
    call ClearCurrentAction()
endfunction

function! s:handlers.error(message)
    call ClearCurrentAction()
    echohl WarningMsg
    echo "ERROR: " a:message['message']
    echohl None
endfunction

function! s:handlers.progress(message)
    call SetCurrentAction(a:message['progressMessage'], 
                \ [ a:message['progressMinimum'],
                \ a:message['progressCurrent'],
                \ a:message['progressMaximum'] ] )
endfunction

function! s:handlers.message(message)
    if index(keys(a:message), 'title') == -1
        echom "kek" a:message['message']
    endif
endfunction

function! s:handlers.signal(message)
    echom "Signal"
endfunction

function! MessageHandler(channel, msg)
    let message = ParseMessage(a:msg)
    if index(keys(s:handlers), message['type']) > -1
        call s:handlers[message['type']](message)
    else
        echoerr "Unhandled message" message['type']
    endif
endfunction

function! ParseMessage(rawmsg)
    let s:start = '[== "CMake Server" ==['
    let s:startlen = len(s:start)
    let s:end = ']== "CMake Server" ==]'
    let s:endlen = len(s:end)

    let startpos = stridx(a:rawmsg, s:start)
    let endpos = stridx(a:rawmsg, s:end)
    if startpos > -1 && endpos > -1
        let stripped = a:rawmsg[startpos + s:startlen : endpos - 1 ]
        let message = json_decode(stripped)
        if (s:debug)
            echom "Incoming message:" string(message)
        endif
    endif
    if !exists('message') || empty(message)
        echoerr "Failed to parse message"
    endif

    return message
endfunction

function! PrepareAndSendMessage(msg)
    if (s:debug)
        echom "Outgoing message:" string(a:msg)
    endif
    let msgstring = '[== "CMake Server" ==[' . "\n"
    let msgstring .= json_encode(a:msg) . "\n"
    let msgstring .= ']== "CMake Server" ==]' . "\n"
    let server = s:cmake_servers[b:current_build_dir]
    call ch_sendraw(server, msgstring)
endfunction

function! ParseCodeModel(message)
    " if len(a:message['configurations']) != 1
    "     echoerr "Unsupported number of configs"
    "     return
    " endif
    " let config = a:message['configurations'][0]
    " if len(config['projects']) != 1
    "     echoerr "Unsupported number of projects"
    "     return
    " endif
    call SetupDebugWindow(a:message)
endfunction
" }}}

" Server handling {{{
function! StartServer()
    if !IsServerRunning()
        let cmd = ['cmake', '-E', 'server', '--experimental', '--debug']
        let s:cmake_servers[b:current_build_dir] = job_start(cmd, {"callback": "MessageHandler", "exit_cb": "Reap", "mode": "raw"})  
    else
        echohl WarningMsg
        echo "Server already running"
        echohl None
    endif
endfunction

function! IsServerRunning()
    if exists('b:current_build_dir')
        if has_key(s:build_dirs, b:current_build_dir)
            if has_key(s:cmake_servers, b:current_build_dir)
                let server = s:cmake_servers[b:current_build_dir]
                return job_status(server) == "run" 
            endif
        endif
    endif
    return v:false
endfunction

function! CheckServer()
    let server = s:cmake_servers[b:current_build_dir]
    echo "job status:     " job_status(server)
    echo "channel status: " ch_status(job_getchannel(server))
endfunction

function! StopServer()
    if IsServerRunning()
        call job_stop(s:cmake_servers[b:current_build_dir])
        call remove(s:cmake_servers, b:current_build_dir)
        call remove(s:build_dirs, b:current_build_dir)
    endif
endfunction

function! Info()
    let build_dir = b:current_build_dir
    tabnew
    set buftype=nofile
    let lines = [ 's:build_dirs:', string(s:build_dirs), 's:cmake_servers:', string(s:cmake_servers) ]
    let lines += [ "s:generator:", s:generator ]
    call setline(1, lines)
endfunction

function! Reap()
    call remove(s:cmake_servers, b:current_build_dir)
    call remove(s:build_dirs, b:current_build_dir)
endfunction

function! SetupDebugWindow(message)
    tabnew
    setlocal buftype=nofile
    setlocal bufhidden=hide
    setlocal noswapfile
    setlocal filetype=json
    file codemodel
    let json = systemlist(s:jq_command . ' .', json_encode(a:message))
    call setline(1, json)
endfunction
" }}}

" Building {{{
function! UpdateMakeprg(build_dir, target)
    let &l:makeprg = printf(s:cmake_build_command, a:build_dir, a:target)
endfunction

function! CompileCurrentFile()
    let current_file = expand('%:p')
    if filereadable(b:current_build_dir . '/compile_commands.json')
        let compile_commands = json_decode(join(readfile(b:current_build_dir . '/compile_commands.json'), "\n"))
        for c in compile_commands
            if c['file'] == current_file
                let current_compile_command = c
                break
            endif
        endfor

        echo current_compile_command['command']
        let tmp = &l:makeprg
        let &l:makeprg = printf('cd "%s" && %s', current_compile_command['directory'], current_compile_command['command'])
        
        augroup CompileCurrentFile
        au!
        autocmd QuickfixCmdPost * let w:quickfix_title = 'Compiler output ' . expand('%')
        augroup END
        make

        let &l:makeprg = tmp
    else
        let response = input('Compiler database not found, do you want to create it?')
        if response =~ '^[Yy]$'
            call SendConfigureCompileCommands()
        endif
    endif
endfunction
" }}}

" Setup {{{
function! DetectCmake()
    if exists('b:cmake_did_detection')
        return
    endif
    let b:cmake_did_detection = v:true
    let b:current_target = s:default_target

    let b:current_build_dir = ''
    for dirpattern in s:cmake_build_dirs
        let dirs = glob(dirpattern, v:false, v:true)
        for dir in dirs
            let match = finddir(dir, ';')
            if !empty(match) && filereadable(match . '/CMakeCache.txt')
                let b:current_build_dir = fnamemodify(match, ':p')
                let s:build_dirs[b:current_build_dir] = 1
                break
            endif
        endfor
    endfor

    if !empty(b:current_build_dir)
        if IsServerRunning()
            echom "Server already running for this path"
        else
            call ParseCMakeCache(b:current_build_dir . '/CMakeCache.txt')
            echom "You can call StartServer() now"
        endif
        call UpdateMakeprg(b:current_build_dir, b:current_target)
    else
        echoerr "Could not find build dir"
    endif
endfunction

function! ParseCMakeCache(file)
    let lines = readfile(a:file)
    let s:projectname = split(filter(copy(lines), 'v:val =~ "^CMAKE_PROJECT_NAME"')[0], "=")[1]
    let s:sourcedir = split(filter(copy(lines), 'v:val =~ "^".s:projectname."_SOURCE_DIR"')[0], "=")[1]
    let s:generator = split(filter(copy(lines), 'v:val =~ "^CMAKE_GENERATOR"')[0], "=")[1]
endfunction

autocmd! Filetype c,cpp call DetectCmake()
" }}}

" Specific messages {{{
function! SendHandShake()
    let msg = { "type": "handshake", 
                \ "protocolVersion": s:protocol,
                \ "sourceDirectory": s:sourcedir,
                \ "generator": s:generator,
                \ "buildDirectory": b:current_build_dir }
    call PrepareAndSendMessage(msg)
endfunction

function! SendConfigure()
    let msg = { "type": "configure" }
    call PrepareAndSendMessage(msg)
endfunction

function! SendConfigureCompileCommands()
    let msg = { "type": "configure", "cacheArguments":["-DCMAKE_EXPORT_COMPILE_COMMANDS=ON"] }
    call PrepareAndSendMessage(msg)
endfunction

function! SendCompute()
    let msg = { "type": "compute" }
    call PrepareAndSendMessage(msg)
endfunction

function! GetCodeModel()
    let msg = { "type": "codemodel" }
    call PrepareAndSendMessage(msg)
endfunction
" }}}

" Status line / progress {{{ 
let s:current_action = ''
let s:progress = [0, 0, 0]

function! CmakeStatusLine()
    if !IsServerRunning()
        return ''
    endif
    if !empty(s:current_action)
        return printf("%s: %d / %d / %d", s:current_action, s:progress[0], s:progress[1], s:progress[2])
    endif
    return printf("Project: %s | target: %s", s:projectname, b:current_target)
endfunction

function! SetCurrentAction(action, progress)
    let s:current_action = a:action
    let s:progress = a:progress
endfunction

function! ClearCurrentAction()
    let s:current_action = ''
    let s:progress = [0, 0, 0]
endfunction
"}}}

" Helper functions {{{
let s:include_path_filter = ''

function! s:jq(json, filter)
    return system(s:jq_command . ' ' . shellescape(filter), json)
endfunction

function s:filter_external(data, filter)
    let json = json_encode(data)
    let filtered_json = s:jq(json, filter)
    return json_decode(filtered_json)
endfunction
" }}}
