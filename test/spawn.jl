# This file is a part of Julia. License is MIT: https://julialang.org/license

###################################
# Cross Platform tests for spawn. #
###################################

using Random, Sockets, SHA
using Downloads: Downloads, download

valgrind_off = ccall(:jl_running_on_valgrind, Cint, ()) == 0

yescmd = `yes`
echocmd = `echo`
sortcmd = `sort`
printfcmd = `printf`
truecmd = `true`
falsecmd = `false`
catcmd = `cat`
shcmd = `sh`
sleepcmd = `sleep`
lscmd = `ls`
havebb = false

busybox_hash_correct(file) = bytes2hex(open(SHA.sha256, file)) == "ed2f95da9555268e93c7af52feb48e148534ee518b9128f65dda9a2767b61b9e"

function _tryonce_download_from_cache(desired_url::AbstractString)
    cache_url = "https://cache.julialang.org/$(desired_url)"
    cache_output_filename = joinpath(mktempdir(), "busybox" * (Sys.iswindows() ? ".exe" : ""))
    cache_response = Downloads.request(
        cache_url;
        output = cache_output_filename,
        throw = false,
        timeout = 60,
    )
    if cache_response isa Downloads.Response
        if Downloads.status_ok(cache_response.proto, cache_response.status)
            if busybox_hash_correct(cache_output_filename)
                return cache_output_filename
            else
                @warn "The busybox executable downloaded from the cache has an incorrect hash" cache_output_filename bytes2hex(open(SHA.sha256, cache_output_filename))
            end
        end
    end
    @warn "Could not download from cache at $cache_url, falling back to primary source at $desired_url"
    return Downloads.download(desired_url; timeout = 60)
end

function download_from_cache(desired_url::AbstractString)
    f = () -> _tryonce_download_from_cache(desired_url)
    delays = Float64[30, 30, 60, 60, 60]
    g = retry(f; delays)
    return g()
end

if Sys.iswindows()
    # See https://frippery.org/files/busybox/
    # latest as of 2024-09-20 18:08
    busybox = download_from_cache("https://frippery.org/files/busybox/busybox-w32-FRP-5467-g9376eebd8.exe")
    busybox_hash_correct(busybox) || error("The busybox executable downloaded has an incorrect hash")

    havebb = try # use busybox-w32 on windows, if available
        success(`$busybox`)
        true
    catch
        false
    end
    if havebb
        yescmd = `$busybox yes`
        echocmd = `$busybox echo`
        sortcmd = `$busybox sort`
        printfcmd = `$busybox printf`
        truecmd = `$busybox true`
        falsecmd = `$busybox false`
        catcmd = `$busybox cat`
        shcmd = `$busybox sh`
        sleepcmd = `$busybox sleep`
        lscmd = `$busybox ls`
    end
end

#### Examples used in the manual ####

@test read(`$echocmd hello \| sort`, String) == "hello | sort\n"
@test read(pipeline(`$echocmd hello`, sortcmd), String) == "hello\n"
@test length(run(pipeline(`$echocmd hello`, sortcmd), wait=false).processes) == 2

out = read(`$echocmd hello` & `$echocmd world`, String)
@test occursin("world", out)
@test occursin("hello", out)
@test read(pipeline(`$echocmd hello` & `$echocmd world`, sortcmd), String) == "hello\nworld\n"

@test_warn r"[stdio passthrough ok]" run(pipeline(`$printfcmd "       \033[34m[stdio passthrough ok]\033[0m\n"`, stdout=stderr, stderr=stderr))

# Test for SIGPIPE being a failure condition
@test_throws ProcessFailedException run(pipeline(yescmd, `head`, devnull))

let p = run(pipeline(yescmd, devnull), wait=false)
    t = @async kill(p)
    @test !success(p)
    wait(t)
end

if valgrind_off
    # If --trace-children=yes is passed to valgrind, valgrind will
    # exit here with an error code, and no IOError will be raised.
    @test_throws Base.IOError run(`foo_is_not_a_valid_command`)
end

if Sys.isunix()
    prefixer(prefix, sleep) = `sh -c "while IFS= read REPLY; do echo '$prefix ' \$REPLY; sleep $sleep; done"`
    @test success(pipeline(`sh -c "for i in 1 2 3 4 5 6 7 8 9 10; do echo \$i; sleep 0.1; done"`,
                       prefixer("A", 0.2) & prefixer("B", 0.2)))
    @test success(pipeline(`sh -c "for i in 1 2 3 4 5 6 7 8 9 10; do echo \$i; sleep 0.1; done"`,
                       prefixer("X", 0.3) & prefixer("Y", 0.3) & prefixer("Z", 0.3),
                       prefixer("A", 0.2) & prefixer("B", 0.2)))
end

@test  success(truecmd)
@test !success(falsecmd)
@test success(pipeline(truecmd, truecmd))
@test_broken  success(ignorestatus(falsecmd))
@test_broken  success(pipeline(ignorestatus(falsecmd), truecmd))
@test !success(pipeline(ignorestatus(falsecmd), falsecmd))
@test !success(ignorestatus(falsecmd) & falsecmd)
@test_broken  success(ignorestatus(pipeline(falsecmd, falsecmd)))
@test_broken  success(ignorestatus(falsecmd & falsecmd))

# stdin Redirection
let file = tempname()
    run(pipeline(`$echocmd hello world`, file))
    @test read(pipeline(file, catcmd), String) == "hello world\n"
    @test open(x->read(x,String), pipeline(file, catcmd), "r") == "hello world\n"
    rm(file)
end

# Stream Redirection
if !Sys.iswindows() # WINNT reports operation not supported on socket (ENOTSUP) for this test
    local r = Channel(1)
    local port, server, sock, client, t1, t2
    t1 = @async begin
        port, server = listenany(2326)
        put!(r, port)
        client = accept(server)
        @test read(pipeline(client, catcmd), String) == "hello world\n"
        close(server)
        return true
    end
    t2 = @async begin
        sock = connect(fetch(r))
        run(pipeline(`$echocmd hello world`, sock))
        close(sock)
        return true
    end
    @test fetch(t1)
    @test fetch(t2)
end

@test read(setenv(`$shcmd -c "echo \$TEST"`,["TEST=Hello World"]), String) == "Hello World\n"
@test read(setenv(`$shcmd -c "echo \$TEST"`,Dict("TEST"=>"Hello World")), String) == "Hello World\n"
@test read(setenv(`$shcmd -c "echo \$TEST"`,"TEST"=>"Hello World"), String) == "Hello World\n"
@test (withenv("TEST"=>"Hello World") do
       read(`$shcmd -c "echo \$TEST"`, String); end) == "Hello World\n"
let pathA = readchomp(setenv(`$shcmd -c "pwd -P"`;dir="..")),
    pathB = readchomp(setenv(`$shcmd -c "cd .. && pwd -P"`))
    if Sys.iswindows()
        # on windows, sh returns posix-style paths that are not valid according to ispath
        @test pathA == pathB
    else
        @test Base.samefile(pathA, pathB)
    end
end

let str = "", proc, str2, file
    for i = 1:1000
      str = "$str\n $(randstring(10))"
    end

    # Here we test that if we close a stream with pending writes, we don't lose the writes.
    @sync begin
        proc = open(`$catcmd -`, "r+")
        @async begin
            write(proc, str) # TODO: use Base.uv_write_async to restore the intended functionality of this test
            close(proc.in)
        end
        str2 = read(proc, String)
        @test str2 == str
    end

    # This test hangs if the end-of-run-walk-across-uv-streams calls shutdown on a stream that is shutting down.
    file = tempname()
    open(pipeline(`$catcmd -`, file), "w") do io
        write(io, str)
    end
    rm(file)
end

# issue #3373
# fixing up Conditions after interruptions
let r, t
    r = Channel(1)
    t = @async begin
        try
            wait(r)
            @test false
        catch ex
            @test isa(ex, InterruptException)
        end
        p = run(`$sleepcmd 1`, wait=false)
        wait(p)
        @test p.exitcode == 0
        return true
    end
    yield()
    schedule(t, InterruptException(), error=true)
    yield()
    put!(r, 11)
    yield()
    @test fetch(t)
end

# Test marking of IO
let r, t, sock
    r = Channel(1)
    t = @async begin
        port, server = listenany(2327)
        put!(r, port)
        client = accept(server)
        write(client, "Hello, world!\n")
        write(client, "Goodbye, world...\n")
        close(server)
        return true
    end
    sock = connect(fetch(r))
    mark(sock)
    @test ismarked(sock)
    @test readline(sock) == "Hello, world!"
    @test readline(sock) == "Goodbye, world..."
    @test reset(sock) == 0
    @test !ismarked(sock)
    mark(sock)
    @test ismarked(sock)
    @test readline(sock) == "Hello, world!"
    unmark(sock)
    @test !ismarked(sock)
    @test_throws ArgumentError reset(sock)
    @test !unmark(sock)
    @test readline(sock) == "Goodbye, world..."
    #@test eof(sock) ## doesn't work
    close(sock)
    @test fetch(t)
end

# issue #4535
exename = `$(Base.julia_cmd()) --startup-file=no --color=no`
if valgrind_off
    # If --trace-children=yes is passed to valgrind, we will get a
    # valgrind banner here, not "Hello World\n".
    @test read(pipeline(`$exename -e 'println(stderr,"Hello World")'`, stderr=catcmd), String) == "Hello World\n"
    out = Pipe()
    proc = run(pipeline(`$exename -e 'println(stderr,"Hello World")'`, stderr = out), wait=false)
    close(out.in)
    @test read(out, String) == "Hello World\n"
    @test success(proc)
end

# setup_stdio for AbstractPipe
let out = Pipe(),
    proc = run(pipeline(`$exename -e 'println(getpid())'`, stdout=IOContext(out, :foo => :bar)), wait=false)
    # < don't block here before getpid call >
    pid = getpid(proc)
    close(out.in)
    @test parse(Int32, read(out, String)) === pid > 1
    @test success(proc)
    @test_throws Base.IOError getpid(proc)
end

# issue #5904
@test run(pipeline(ignorestatus(falsecmd), truecmd)) isa Base.AbstractPipe

@testset "redirect_*" begin
    let OLD_STDOUT = stdout,
        fname = tempname(),
        f = open(fname,"w")

        redirect_stdout(f)
        println("Hello World")
        redirect_stdout(OLD_STDOUT)
        close(f)
        @test "Hello World\n" == read(fname, String)
        @test OLD_STDOUT === stdout
        rm(fname)

        col = get(stdout, :color, false)
        redirect_stdout(IOContext(stdout, :color=>!col))
        @test get(stdout, :color, col) == !col
        redirect_stdout(OLD_STDOUT)
    end
end

@testset "redirect_stdio" begin

    function hello_err_out()
        println(stderr, "hello from stderr")
        println(stdout, "hello from stdout")
    end
    @testset "same path for multiple streams" begin
        @test_throws ArgumentError redirect_stdio(hello_err_out,
                                            stdin="samepath.txt", stdout="samepath.txt")
        @test_throws ArgumentError redirect_stdio(hello_err_out,
                                            stdin="samepath.txt", stderr="samepath.txt")

        @test_throws ArgumentError redirect_stdio(hello_err_out,
                                            stdin=joinpath("tricky", "..", "samepath.txt"),
                                            stderr="samepath.txt")
        mktempdir() do dir
            path = joinpath(dir, "stdouterr.txt")
            redirect_stdio(hello_err_out, stdout=path, stderr=path)
            @test read(path, String) == """
            hello from stderr
            hello from stdout
            """
        end
    end

    mktempdir() do dir
        path_stdout = joinpath(dir, "stdout.txt")
        path_stderr = joinpath(dir, "stderr.txt")
        redirect_stdio(hello_err_out, stderr=devnull, stdout=path_stdout)
        @test read(path_stdout, String) == "hello from stdout\n"

        open(path_stderr, "w") do ioerr
            redirect_stdio(hello_err_out, stderr=ioerr, stdout=devnull)
        end
        @test read(path_stderr, String) == "hello from stderr\n"
    end

    mktempdir() do dir
        path_stderr = joinpath(dir, "stderr.txt")
        path_stdin  = joinpath(dir, "stdin.txt")
        path_stdout = joinpath(dir, "stdout.txt")

        content_stderr = randstring()
        content_stdout = randstring()

        redirect_stdio(stdout=path_stdout, stderr=path_stderr) do
            print(content_stdout)
            print(stderr, content_stderr)
        end

        @test read(path_stderr, String) == content_stderr
        @test read(path_stdout, String) == content_stdout
    end

    # stdin is unavailable on the workers. Run test on master.
    ret = Core.eval(Main,
            quote
                remotecall_fetch(1) do
                    mktempdir() do dir
                        path = joinpath(dir, "stdin.txt")
                        write(path, "hello from stdin\n")
                        redirect_stdio(readline, stdin=path)
                    end
                end
            end)
    @test ret == "hello from stdin"
end

# issue #36136
@testset "redirect to devnull" begin
    @test redirect_stdout(devnull) do; println("Hello") end === nothing
    @test redirect_stderr(devnull) do; println(stderr, "Hello") end === nothing
    # stdin is unavailable on the workers. Run test on master.
    ret = Core.eval(Main, quote
                remotecall_fetch(1) do
                    redirect_stdin(devnull) do; read(stdin, String) end
                end
            end)
    @test ret == ""
end

# Test that redirecting an IOStream does not crash the process
let fname = tempname(), p
    cmd = """
    # Overwrite libuv memory before freeing it, to make sure that a use after free
    # triggers an assertion.
    function thrash(handle::Ptr{Cvoid})
        # Kill the memory, but write a nice low value in the libuv type field to
        # trigger the right code path
        ccall(:memset, Ptr{Cvoid}, (Ptr{Cvoid}, Cint, Csize_t), handle, 0xee, 3 * sizeof(Ptr{Cvoid}))
        unsafe_store!(convert(Ptr{Cint}, handle + 2 * sizeof(Ptr{Cvoid})), 15)
        nothing
    end
    OLD_STDERR = stderr
    redirect_stderr(open($(repr(fname)), "w"))
    # Usually this would be done by GC. Do it manually, to make the failure
    # case more reliable.
    oldhandle = OLD_STDERR.handle
    OLD_STDERR.status = Base.StatusClosing
    OLD_STDERR.handle = C_NULL
    ccall(:uv_close, Cvoid, (Ptr{Cvoid}, Ptr{Cvoid}), oldhandle, @cfunction(thrash, Cvoid, (Ptr{Cvoid},)))
    sleep(1)
    import Base.zzzInvalidIdentifier
    """
    try
        io = open(pipeline(exename, stderr=stderr), "w")
        write(io, cmd)
        close(io)
        wait(io)
    catch
        error("IOStream redirect failed. Child stderr was \n$(read(fname, String))\n")
    finally
        rm(fname)
    end
end

# issue #10994: libuv can't handle strings containing NUL
let bad = "bad\0name"
    @test_throws ArgumentError run(`$bad`)
    @test_throws ArgumentError run(`$echocmd $bad`)
    @test_throws ArgumentError run(setenv(`$echocmd hello`, bad=>"good"))
    @test_throws ArgumentError run(setenv(`$echocmd hello`, "good"=>bad))
end

# issue #12829
let out = Pipe(), echo = `$exename -e 'print(stdout, " 1\t", read(stdin, String))'`, ready = Condition(), t, infd, outfd
    @test_throws ArgumentError write(out, "not open error")
    inread = false
    t = @async begin # spawn writer task
        open(echo, "w", out) do in1
            open(echo, "w", out) do in2
                notify(ready)
                write(in1, 'h')
                write(in2, UInt8['w'])
                println(in1, "ello")
                write(in2, "orld\n")
            end
        end
        infd = Base._fd(out.in)
        outfd = Base._fd(out.out)
        inread || wait(ready)
        show(out, out)
        @test isreadable(out)
        @test iswritable(out)
        close(out.in)
        @test !isopen(out.in)
        @test !iswritable(out)
        if !Sys.iswindows()
            # on UNIX, we expect the pipe buffer is big enough that the write queue was immediately emptied
            # and so we should already be notified of EPIPE on out.out by now
            # and the other task should have already managed to consume all of the output
            # it takes longer to propagate EOF through the Windows event system
            # since it appears to be unwilling to buffer as much data
            @test !isopen(out.out)
            @test !isreadable(out)
        end
        @test_throws Base.IOError write(out, "now closed error")
        if Sys.iswindows()
            # WINNT kernel appears to not provide a fast mechanism for async propagation
            # of EOF for a blocking stream, so just wait for it to catch up.
            # This shouldn't take much more than 32ms more.
            Base.wait_close(out)
        end
        @test !isopen(out)
    end
    wait(ready) # wait for writer task to be ready before using `out`
    @test bytesavailable(out) == 0
    @test endswith(readuntil(out, '1', keep=true), '1')
    @test Char(read(out, UInt8)) == '\t'
    c = UInt8[0]
    @test c == read!(out, c)
    Base.wait_readnb(out, 1)
    @test bytesavailable(out) > 0
    ln1 = readline(out)
    ln2 = readline(out)
    inread = true
    notify(ready)
    desc = read(out, String)
    @test !isreadable(out)
    @test !iswritable(out)
    @test !isopen(out)
    @test infd != Base._fd(out.in) == Base.INVALID_OS_HANDLE
    @test outfd != Base._fd(out.out) == Base.INVALID_OS_HANDLE
    @test bytesavailable(out) == 0
    @test c == UInt8['w']
    @test lstrip(ln2) == "1\thello"
    @test ln1 == "orld"
    @test isempty(read(out))
    @test eof(out)
    @test desc == "Pipe($infd open => $outfd active, 0 bytes waiting)"
    Base.wait(t)
end

# issue #8529
let fname = tempname()
    write(fname, "test\n")
    code = """
    $(if havebb
        "cmd = pipeline(`\$$(repr(busybox)) echo asdf`, `\$$(repr(busybox)) cat`)"
    else
        "cmd = pipeline(`echo asdf`, `cat`)"
    end)
    for line in eachline(stdin)
        run(cmd)
    end
    """
    @test success(pipeline(`$catcmd $fname`, `$exename -e $code`))
    rm(fname)
end

# Ensure that quoting works
@test Base.shell_split("foo bar baz") == ["foo", "bar", "baz"]
@test Base.shell_split("foo\\ bar baz") == ["foo bar", "baz"]
@test Base.shell_split("'foo bar' baz") == ["foo bar", "baz"]
@test Base.shell_split("\"foo bar\" baz") == ["foo bar", "baz"]

# "Over quoted"
@test Base.shell_split("'foo\\ bar' baz") == ["foo\\ bar", "baz"]
@test Base.shell_split("\"foo\\ bar\" baz") == ["foo\\ bar", "baz"]

# Ensure that shell_split handles quoted spaces
let cmd = ["/Volumes/External HD/program", "-a"]
    @test Base.shell_split("/Volumes/External\\ HD/program -a") == cmd
    @test Base.shell_split("'/Volumes/External HD/program' -a") == cmd
    @test Base.shell_split("\"/Volumes/External HD/program\" -a") == cmd
end

# Test shell_escape printing quoting
# Backticks should automatically quote where necessary
let cmd = ["foo bar", "baz", "a'b", "a\"b", "a\"b\"c", "-L/usr/+", "a=b", "``", "\$", "&&", "", "z"]
    @test string(`$cmd`) ==
        """`'foo bar' baz "a'b" 'a"b' 'a"b"c' -L/usr/+ a=b \\`\\` '\$' '&&' '' z`"""
    @test Base.shell_escape(`$cmd`) ==
        """'foo bar' baz "a'b" 'a"b' 'a"b"c' -L/usr/+ a=b `` '\$' && '' z"""
    @test Base.shell_escape_posixly(`$cmd`) ==
        """'foo bar' baz a\\'b a\\"b 'a"b"c' -L/usr/+ a=b '``' '\$' '&&' '' z"""
end
let cmd = ["foo=bar", "baz"]
    @test string(`$cmd`) == "`foo=bar baz`"
    @test Base.shell_escape(`$cmd`) == "foo=bar baz"
    @test Base.shell_escape_posixly(`$cmd`) == "'foo=bar' baz"
end


@test Base.shell_split("\"\\\\\"") == ["\\"]

# Test failing commands
failing_cmd = `$catcmd _doesnt_exist__111_`
failing_pipeline = pipeline(failing_cmd, stderr=devnull) # make quiet for tests
for testrun in (failing_pipeline, pipeline(failing_pipeline, failing_pipeline))
    try
        run(testrun)
    catch err
        @test err isa ProcessFailedException
        errmsg = sprint(showerror, err)
        @test occursin(string(failing_cmd), errmsg)
    end
end

# issue #13616
@test_throws(ProcessFailedException, collect(eachline(failing_pipeline)))


# make sure windows_verbatim strips quotes
if Sys.iswindows()
    @test read(`cmd.exe /c dir /b spawn.jl`, String) == read(Cmd(`cmd.exe /c dir /b "\"spawn.jl\""`, windows_verbatim=true), String)
end

# make sure Cmd is nestable
@test string(Cmd(Cmd(`ls`, detach=true))) == "`ls`"

# equality tests for Cmd
@test Base.Cmd(``) == Base.Cmd(``)
@test Base.Cmd(`lsof -i :9090`) == Base.Cmd(`lsof -i :9090`)
@test Base.Cmd(`$echocmd test`) == Base.Cmd(`$echocmd test`)
@test Base.Cmd(``) != Base.Cmd(`$echocmd test`)
@test Base.Cmd(``, ignorestatus=true) != Base.Cmd(``, ignorestatus=false)
@test Base.Cmd(``, dir="TESTS") != Base.Cmd(``, dir="TEST")
@test Base.Set([``, ``]) == Base.Set([``])
@test Set([``, echocmd]) != Set([``, ``])
@test Set([echocmd, ``, ``, echocmd]) == Set([echocmd, ``])

# env handling (#32454)
@test Cmd(`foo`, env=Dict("A"=>true)).env == ["A=true"]
@test Cmd(`foo`, env=["A=true"]).env      == ["A=true"]
@test Cmd(`foo`, env=("A"=>true,)).env    == ["A=true"]
@test Cmd(`foo`, env=["A"=>true]).env     == ["A=true"]
@test Cmd(`foo`, env=nothing).env         === nothing

# test for interpolation of Cmd
let c = setenv(`x`, "A"=>true)
    @test (`$c a`).env == String["A=true"]
    @test (`"$c" a`).env == String["A=true"]
    @test_throws ArgumentError `a $c`
    @test (`$(c.exec) a`).env === nothing
    @test_throws ArgumentError `"$c "`
end

# Interaction of cmd parsing with var syntax (#32408)
let var = "x", vars="z"
    @test `ls $var` == Cmd(["ls", "x"])
    @test `ls $vars` == Cmd(["ls", "z"])
    @test `ls $var"y"` == Cmd(["ls", "xy"])
    @test `ls "'$var'"` == Cmd(["ls", "'x'"])
    @test `ls $var "y"` == Cmd(["ls", "x", "y"])
end

# equality tests for AndCmds
@test Base.AndCmds(`$echocmd abc`, `$echocmd def`) == Base.AndCmds(`$echocmd abc`, `$echocmd def`)
@test Base.AndCmds(`$echocmd abc`, `$echocmd def`) != Base.AndCmds(`$echocmd abc`, `$echocmd xyz`)

# test for correct error when an empty command is spawned (Issue 19094)
@test_throws ArgumentError run(Base.Cmd(``))
@test_throws ArgumentError run(Base.AndCmds(``, ``))
@test_throws ArgumentError run(Base.AndCmds(``, `$truecmd`))
@test_throws ArgumentError run(Base.AndCmds(`$truecmd`, ``))

# tests for reducing over collection of Cmd
@test_throws "reducing over an empty collection is not allowed" reduce(&, Base.AbstractCmd[])
@test_throws "reducing over an empty collection is not allowed" reduce(&, Base.Cmd[])
@test reduce(&, [`$echocmd abc`, `$echocmd def`, `$echocmd hij`]) == `$echocmd abc` & `$echocmd def` & `$echocmd hij`

# readlines(::Cmd), accidentally broken in #20203
let str = "foo\nbar"
    @test readlines(`$echocmd $str`) == split(str)
end

# issue #19864 (PR #20497)
let c19864 = readchomp(pipeline(ignorestatus(
        `$exename -e '
            struct Error19864 <: Exception; end
            Base.showerror(io::IO, e::Error19864) = print(io, "correct19864")
            throw(Error19864())'`),
    stderr=catcmd))
    @test occursin("ERROR: correct19864", c19864)
end

# accessing the command elements as an array or iterator:
let c = `ls -l "foo bar"`
    @test collect(c) == ["ls", "-l", "foo bar"]
    @test collect(Iterators.reverse(c)) == reverse!(["ls", "-l", "foo bar"])
    @test first(c) == "ls" == c[1]
    @test last(c) == "foo bar" == c[3] == c[end]
    @test c[1:2] == ["ls", "-l"]
    @test eltype(c) == String
    @test length(c) == 3
    @test eachindex(c) == 1:3
end

## Deadlock in spawning a cmd (#22832)
let out = Pipe(), inpt = Pipe()
    Base.link_pipe!(out, reader_supports_async=true)
    Base.link_pipe!(inpt, writer_supports_async=true)
    p = run(pipeline(catcmd, stdin=inpt, stdout=out, stderr=devnull), wait=false)
    t = @async begin # feed cat with 2 MB of data (zeros)
        write(inpt, zeros(UInt8, 1048576 * 2))
        close(inpt)
    end
    sleep(1) # give cat a chance to fill the write buffer for stdout
    close(inpt.out)
    close(out.in) # make sure we can still close the write end
    @test sizeof(read(out)) == 1048576 * 2 # make sure we get all the data
    @test success(p)
    wait(t)
end

# `kill` error conditions
let p = run(`$sleepcmd 100`, wait=false)
    # Should throw on invalid signals
    @test_throws Base.IOError kill(p, typemax(Cint))
    kill(p)
    wait(p)
    # Should not throw if already dead
    kill(p)
end

# Second return of shell_parse
let s = "   \$abc   "
    @test Base.shell_parse(s)[2] === findfirst('a', s)
    s = "abc def"
    @test Base.shell_parse(s)[2] === findfirst('d', s)
    s = "abc 'de'f\"\"g"
    @test Base.shell_parse(s)[2] === findfirst('\'', s)
    s = "abc \$x'de'f\"\"g"
    @test Base.shell_parse(s)[2] === findfirst('\'', s)
    s = "abc def\$x'g'"
    @test Base.shell_parse(s)[2] === findfirst('\'', s)
    s = "abc def\$x "
    @test Base.shell_parse(s)[2] === findfirst('x', s)
    s = "abc \$(d)ef\$(x "
    @test Base.shell_parse(s)[2] === findfirst('x', s) - 1
end

# Logging macros should not output to finalized streams (#26687)
let
    cmd = `$exename -e 'finalizer(x->@info(x), "Hello")'`
    output = readchomp(pipeline(cmd, stderr=catcmd))
    @test occursin("Info: Hello", output)
end

# Sys.which() testing
psep = if Sys.iswindows() ";" else ":" end
withenv("PATH" => "$(Sys.BINDIR)$(psep)$(ENV["PATH"])") do
    julia_exe = joinpath(Sys.BINDIR, Base.julia_exename())
    @test Sys.which(Base.julia_exename()) == abspath(julia_exe)
    @test Sys.which(julia_exe) == abspath(julia_exe)
end

# Check that which behaves correctly when passed an empty string
@test isnothing(Base.Sys.which(""))


mktempdir() do dir
    withenv("PATH" => "$(dir)$(psep)$(ENV["PATH"])") do
        # Test that files lacking executable permissions fail Sys.which
        # but only on non-Windows systems, as Windows doesn't care...
        foo_path = joinpath(dir, "foo")
        touch(foo_path)
        chmod(foo_path, 0o777)
        if !Sys.iswindows()
            @test Sys.which("foo") == abspath(foo_path)
            @test Sys.which(foo_path) == abspath(foo_path)

            chmod(foo_path, 0o666)
            @test Sys.which("foo") === nothing
            @test Sys.which(foo_path) === nothing
        end

    end

    # Ensure these tests are done only with a PATH of known contents
    withenv("PATH" => "$(dir)") do
        # Test that completely missing files also return nothing
        @test Sys.which("this_is_not_a_command") === nothing

        # Check that which behaves correctly when passed a blank string
        @test isnothing(Base.Sys.which(" "))
    end
end

mktempdir() do dir
    withenv("PATH" => "$(joinpath(dir, "bin1"))$(psep)$(joinpath(dir, "bin2"))$(psep)$(ENV["PATH"])") do
        # Test that we have proper priorities
        mkpath(joinpath(dir, "bin1"))
        mkpath(joinpath(dir, "bin2"))
        foo1_path = joinpath(dir, "bin1", "foo")
        foo2_path = joinpath(dir, "bin2", "foo")

        # On windows, we find things with ".exe" and ".com"
        if Sys.iswindows()
            foo1_path *= ".exe"
            foo2_path *= ".com"
        end

        touch(foo1_path)
        touch(foo2_path)
        chmod(foo1_path, 0o777)
        chmod(foo2_path, 0o777)
        @test Sys.which("foo") == abspath(foo1_path)

        # chmod() doesn't change which() on Windows, so don't bother to test that
        if !Sys.iswindows()
            chmod(foo1_path, 0o666)
            @test Sys.which("foo") == abspath(foo2_path)
            chmod(foo1_path, 0o777)
        end

        if Sys.iswindows()
            # On windows, check that pwd() takes precedence, except when we provide a path
            cd(joinpath(dir, "bin2")) do
                @test Sys.which("foo") == abspath(foo2_path)
                @test Sys.which(foo1_path) == abspath(foo1_path)
            end
        end

        # Check that "bin1/bar" will actually run "bin1/bar"
        bar_path = joinpath(dir, "bin1", "bar")
        if Sys.iswindows()
            bar_path *= ".exe"
        end

        touch(bar_path)
        chmod(bar_path, 0o777)
        cd(dir) do
            p = Sys.which(joinpath("bin1", "bar"))
            @test p == abspath("bin1", basename(bar_path))
            @test Base.samefile(p, bar_path)
        end
    end
end

# Issue #27550: make sure `peek` works when slurping a Char from an AbstractPipe
open(`$catcmd`, "r+") do f
    t = @async begin
        write(f, "δ")
        close(f.in)
    end
    @test read(f, Char) == 'δ'
    wait(t)
end

# issue #32193
mktemp() do path, io
    redirect_stderr(io) do
        @test_throws ProcessFailedException open(identity, `$catcmd _doesnt_exist__111_`, read=true)
    end
end

let text = "input-test-text"
    b = PipeBuffer()
    proc = open(Base.CmdRedirect(Base.CmdRedirect(```$exename -E '
                    in14 = Base.open(RawFD(14))
                    out15 = Base.open(RawFD(15))
                    write(out15, in14)'```,
                IOBuffer(text), 14, true),
            b, 15, false), "r")
    @test read(proc, String) == string(length(text), '\n')
    @test success(proc)
    @test String(take!(b)) == text

    out = Base.BufferStream()
    proc = run(catcmd, IOBuffer(text), out, wait=false)
    @test proc.out === out
    @test success(proc)
    closewrite(out)
    @test read(out, String) == text

    out = PipeBuffer()
    proc = run(catcmd, IOBuffer(SubString(text)), out)
    @test success(proc)
    @test proc.out === proc.err === proc.in === devnull
    @test String(take!(out)) == text
end


@test repr(Base.CmdRedirect(``, devnull, 0, false)) == "pipeline(``, stdin>Base.DevNull())"
@test repr(Base.CmdRedirect(``, devnull, 1, true)) == "pipeline(``, stdout<Base.DevNull())"
@test repr(Base.CmdRedirect(``, devnull, 11, true)) == "pipeline(``, 11<Base.DevNull())"


# Issue #37070
@testset "addenv()" begin
    cmd = Cmd(`$shcmd -c "echo \$FOO \$BAR"`, env=Dict("FOO" => "foo"))
    @test strip(String(read(cmd))) == "foo"
    cmd = addenv(cmd, "BAR" => "bar")
    @test strip(String(read(cmd))) == "foo bar"
    cmd = addenv(cmd, Dict("FOO" => "bar"))
    @test strip(String(read(cmd))) == "bar bar"
    cmd = addenv(cmd, ["FOO=baz"])
    @test strip(String(read(cmd))) == "baz bar"

    # Test that `addenv()` works properly with `inherit`
    withenv("FOO" => "foo", "BAR" => nothing) do
        cmd = Cmd(`$shcmd -c "echo \$FOO \$BAR"`)
        @test strip(String(read(cmd))) == "foo"

        cmd2 = addenv(cmd, "BAR" => "bar"; inherit=false)
        @test strip(String(read(cmd2))) == "bar"

        cmd2 = addenv(cmd, "BAR" => "bar"; inherit=true)
        @test strip(String(read(cmd2))) == "foo bar"

        # Changing the environment doesn't effect the command,
        # because it was baked in at `addenv()` time
        withenv("FOO" => "baz") do
            @test strip(String(read(cmd2))) == "foo bar"
        end

        # Even with inheritance, `addenv()` dominates:
        cmd2 = addenv(cmd, "FOO" => "foo2", "BAR" => "bar"; inherit=true)
        @test strip(String(read(cmd2))) == "foo2 bar"
    end
    # Keys with value === nothing are deleted
    cmd = Cmd(`$shcmd -c "echo \$FOO \$BAR"`, env=Dict("FOO" => "foo", "BAR" => "bar"))
    cmd2 = addenv(cmd, "FOO" => nothing)
    @test strip(String(read(cmd2))) == "bar"
    # addenv keeps the cmd's dir (#42131)
    dir = joinpath(pwd(), "dir")
    cmd = addenv(setenv(`julia`; dir=dir), Dict())
    @test cmd.dir == dir

    @test addenv(``, ["a=b=c"], inherit=false).env == ["a=b=c"]
    cmd = addenv(``, "a"=>"b=c", inherit=false)
    @test cmd.env == ["a=b=c"]
    cmd = addenv(cmd, "b"=>"b")
    @test issetequal(cmd.env, ["b=b", "a=b=c"])
end

@testset "setenv with dir (with tests for #42131)" begin
    dir1 = joinpath(pwd(), "dir1")
    dir2 = joinpath(pwd(), "dir2")
    cmd = Cmd(`julia`; dir=dir1)
    @test cmd.dir == dir1
    @test Cmd(cmd).dir == dir1
    @test Cmd(cmd; dir=dir2).dir == dir2
    @test Cmd(cmd; dir="").dir == ""
    @test setenv(cmd).dir == dir1
    @test setenv(cmd; dir=dir2).dir == dir2
    @test setenv(cmd; dir="").dir == ""
    @test setenv(cmd, "FOO"=>"foo").dir == dir1
    @test setenv(cmd, "FOO"=>"foo"; dir=dir2).dir == dir2
    @test setenv(cmd, "FOO"=>"foo"; dir="").dir == ""
    @test setenv(cmd, Dict("FOO"=>"foo")).dir == dir1
    @test setenv(cmd, Dict("FOO"=>"foo"); dir=dir2).dir == dir2
    @test setenv(cmd, Dict("FOO"=>"foo"); dir="").dir == ""
end


# clean up busybox download
if Sys.iswindows()
    rm(busybox, force=true)
end


# test (t)csh escaping if tcsh is installed
cshcmd = "/bin/tcsh"
if isfile(cshcmd)
    csh_echo(s) = chop(read(Cmd([cshcmd, "-c",
                                 "echo " * Base.shell_escape_csh(s)]), String))
    csh_test(s) = csh_echo(s) == s
    @testset "shell_escape_csh" begin
        for s in ["", "-a/b", "'", "'£\"", join(' ':'~') ^ 2,
                  "\t", "\n", "'\n", "\"\n", "'\n\n\""]
            @test csh_test(s)
        end
    end
end

@testset "shell escaping on Windows" begin
    # Note  argument A can be parsed both as A or "A".
    # We do not test that the parsing satisfies either of these conditions.
    # In other words, tests may fail even for valid parsing.
    # This is done to avoid overly verbose tests.

    # input :
    # output: ""
    @test Base.escape_microsoft_c_args("") == "\"\""

    @test Base.escape_microsoft_c_args("A") == "A"

    @test Base.escape_microsoft_c_args(`A`) == "A"

    # input : hello world
    # output: "hello world"
    @test Base.escape_microsoft_c_args("hello world") == "\"hello world\""

    # input : hello  world
    # output: "hello  world"
    @test Base.escape_microsoft_c_args("hello\tworld") == "\"hello\tworld\""

    # input : hello"world
    # output: "hello\"world" (also valid) hello\"world
    @test Base.escape_microsoft_c_args("hello\"world") == "\"hello\\\"world\""

    # input : hello""world
    # output: "hello\"\"world" (also valid) hello\"\"world
    @test Base.escape_microsoft_c_args("hello\"\"world") == "\"hello\\\"\\\"world\""

    # input : hello\world
    # output: hello\world
    @test Base.escape_microsoft_c_args("hello\\world") == "hello\\world"

    # input : hello\\world
    # output: hello\\world
    @test Base.escape_microsoft_c_args("hello\\\\world") == "hello\\\\world"

    # input : hello\"world
    # output: "hello\"world" (also valid) hello\"world
    @test Base.escape_microsoft_c_args("hello\\\"world") == "\"hello\\\\\\\"world\""

    # input : hello\\"world
    # output: "hello\\\\\"world" (also valid) hello\\\\\"world
    @test Base.escape_microsoft_c_args("hello\\\\\"world")  == "\"hello\\\\\\\\\\\"world\""

    # input : hello world\
    # output: "hello world\\"
    @test Base.escape_microsoft_c_args("hello world\\") == "\"hello world\\\\\""

    # input : A\B
    # output: A\B"
    @test Base.escape_microsoft_c_args("A\\B") == "A\\B"

    # input : [A\, B]
    # output: "A\ B"
    @test Base.escape_microsoft_c_args("A\\", "B") == "A\\ B"

    # input : A"B
    # output: "A\"B"
    @test Base.escape_microsoft_c_args("A\"B") ==  "\"A\\\"B\""

    # input : [A B\, C]
    # output: "A B\\" C
    @test Base.escape_microsoft_c_args("A B\\", "C") == "\"A B\\\\\" C"

    # input : [A "B, C]
    # output: "A \"B" C
    @test Base.escape_microsoft_c_args("A \"B", "C") == "\"A \\\"B\" C"

    # input : [A B\, C]
    # output: "A B\\" C
    @test Base.escape_microsoft_c_args("A B\\", "C") == "\"A B\\\\\" C"

    # input :[A\ B\, C]
    # output: "A\ B\\" C
    @test Base.escape_microsoft_c_args("A\\ B\\", "C") == "\"A\\ B\\\\\" C"

    # input : [A\ B\, C, D K]
    # output: "A\ B\\" C "D K"
    @test Base.escape_microsoft_c_args("A\\ B\\", "C", "D K") == "\"A\\ B\\\\\" C \"D K\""

    # shell_escape_wincmd
    @test Base.shell_escape_wincmd("") == ""
    @test Base.shell_escape_wincmd("\"") == "^\""
    @test Base.shell_escape_wincmd("\"\"") == "\"\""
    @test Base.shell_escape_wincmd("\"\"\"") == "\"\"^\""
    @test Base.shell_escape_wincmd("\"\"\"\"") == "\"\"\"\""
    @test Base.shell_escape_wincmd("a^\"^o\"^u\"") == "a^^\"^o\"^^u^\""
    @test Base.shell_escape_wincmd("ä^\"^ö\"^ü\"") == "ä^^\"^ö\"^^ü^\""
    @test Base.shell_escape_wincmd("@@()!^<>&|\"") == "^@@^(^)^!^^^<^>^&^|^\""
    @test_throws ArgumentError Base.shell_escape_wincmd("\0")
    @test_throws ArgumentError Base.shell_escape_wincmd("\r")
    @test_throws ArgumentError Base.shell_escape_wincmd("\n")

    # combined tests of shell_escape_wincmd and escape_microsoft_c_args
    @test Base.shell_escape_wincmd(Base.escape_microsoft_c_args(
        "julia", "-e", "println(ARGS)", raw"He said \"a^2+b^2=c^2\"!" )) ==
            "julia -e println^(ARGS^) \"He said \\\"a^^2+b^^2=c^^2\\\"!\""

    ascii95 = String(range(' ',stop='~')); # all printable ASCII characters
    args = ["ab ^` c", " \" ", "\"", ascii95, ascii95,
            "\"\\\"\\", "", "|", "&&", ";"];
    @test Base.shell_escape_wincmd(Base.escape_microsoft_c_args(args...)) == "\"ab ^` c\" \" \\\" \" \"\\\"\" \" !\\\"#\$%^&'^(^)*+,-./0123456789:;^<=^>?@ABCDEFGHIJKLMNOPQRSTUVWXYZ[\\]^^_`abcdefghijklmnopqrstuvwxyz{^|}~\" \" ^!\\\"#\$%&'()*+,-./0123456789:;<=>?@ABCDEFGHIJKLMNOPQRSTUVWXYZ[\\]^_`abcdefghijklmnopqrstuvwxyz{|}~\" \"\\\"\\\\\\\"\\\\\" \"\" ^| ^&^& ;"
end

# effects for Cmd construction
for f in (() -> `a b c`, () -> `a a$("bb")a $("c")`)
    effects = Base.infer_effects(f)
    @test Core.Compiler.is_effect_free(effects)
    @test Core.Compiler.is_terminates(effects)
    @test Core.Compiler.is_noub(effects)
    @test !Core.Compiler.is_consistent(effects)
end
let effects = Base.infer_effects(x -> `a $x`, (Any,))
    @test !Core.Compiler.is_effect_free(effects)
    @test !Core.Compiler.is_terminates(effects)
    @test !Core.Compiler.is_noub(effects)
    @test !Core.Compiler.is_consistent(effects)
end

# Test that Cmd accepts various AbstractStrings
@testset "AbstractStrings" begin
    args = split("-l /tmp")
    @assert eltype(args) != String
    @test Cmd(["ls", args...]) == `ls -l /tmp`
end
