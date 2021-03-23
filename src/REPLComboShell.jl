module REPLComboShell

using PEG

function process_pipeline(x)
    cmds = collect(Iterators.flatten(x))
    pipeline(cmds...)
end

@PEG.rule script = command[1] & pipe_recv[*] |> process_pipeline
@PEG.rule pipe_recv = r"\|"p & command |> x->x[2]
@PEG.rule command = argument[+] |> (x)->Base.cmd_gen(x)
@PEG.rule argument = word
@PEG.rule word = r"[^|\s\"']+"p

function set_prompt(julsh)
    location = if haskey(ENV, "SSH_CONNECTION")
        hostname = gethostname()
        "$hostname "
    else
        ""
    end
    path = replace(pwd(), homedir() => "~")
    branch = if isfile(".git/HEAD")
        head = readchomp(".git/HEAD")
        matching = match(r"ref: refs/heads/(.+)", head)
        label = if isnothing(matching)
            "detached"
        else
            matching.captures[1]
        end
        " $label"
    else
        ""
    end
    julsh.prompt = repeat(" ", length(location) + length(path) + length(branch) + 2)
    julsh.prompt_suffix = "\x1b[G$location\x1b[32m$path\x1b[36m$branch\x1b[39m> "
end

function is_shell_command(s)
    args = split(s, ' ')
    !isnothing(Sys.which(args[1])) && args[1] != "import" || args[1] == "cd"
end

using REPL
import REPL.LineEdit

struct JulishCompletionProvider <: REPL.LineEdit.CompletionProvider end

def_completions = REPL.REPLCompletionProvider()

function REPL.complete_line(c::JulishCompletionProvider, s::REPL.LineEdit.PromptState)
    partial = REPL.beforecursor(s.input_buffer)
    if is_shell_command(partial)
        completion_command = Base.shell_escape(`complete -C "$partial"`)
        fish_complete = readlines(`fish -c "$completion_command"`)
        fish_complete = map(x->split(x, '\t')[1], fish_complete)
        ret = REPL.REPLCompletions.Completion[REPL.REPLCompletions.PathCompletion(x) for x in fish_complete]
        range = findlast(' ', partial)+1:length(partial)
        ret = unique!(map(REPL.REPLCompletions.completion_text, ret))
        should_complete = length(ret)==1
        return ret, partial[range], should_complete
    else
        return REPL.complete_line(def_completions, s)
    end
end

function setup_repl(repl)
    julsh = LineEdit.Prompt("test>";
        prompt_prefix = "",
        prompt_suffix = "",
        keymap_dict   = REPL.LineEdit.default_keymap_dict,
        on_enter      = (s -> true),
        complete      = JulishCompletionProvider(),
        sticky        = true,
    )

    function parse_to_expr(s)
        args = split(s, ' ')
        if !isnothing(Sys.which(args[1])) && args[1] != "import"
            cmd = parse_whole(script, s)
            open(pipeline(stdin, ignorestatus(cmd), stdout), "r") do io
                while true
                    try
                        sleep(0) # Required? Yes. Cursed? Yep!
                        success(io)
                        break
                    catch
                    end
                end
            end
            set_prompt(julsh);
            nothing
        elseif args[1] == "cd"
            if length(args) != 2
                cd()
            elseif !isdir(args[2])
                println("$(args[2]): directory not found")
            else
                cd(expanduser(args[2]));
            end
            set_prompt(julsh);
            nothing
        else
            Meta.parse(s)
        end
    end

    set_prompt(julsh)
    
    if !isdefined(repl, :interface)
        repl.interface = REPL.setup_interface(repl)
    end

    julsh.on_done = REPL.respond(parse_to_expr, repl, julsh)

    main_mode = repl.interface.modes[1]
    help_mode = repl.interface.modes[3]
    history_mode = repl.interface.modes[4]
    pkg_mode = repl.interface.modes[end]

    history_mode.hp.mode_mapping[:julsh] = julsh
    julsh.hist = history_mode.hp

    search_prompt, skeymap = LineEdit.setup_search_keymap(history_mode.hp)

    julsh.keymap_dict = LineEdit.keymap(Dict{Any,Any}[
        skeymap,
        REPL.mode_keymap(main_mode),
        LineEdit.history_keymap,
        LineEdit.default_keymap,
        LineEdit.escape_defaults,
    ])

    julsh.keymap_dict = LineEdit.keymap_merge(julsh.keymap_dict, Dict{Any, Any}(
        '\b' => function (s, args...)
            LineEdit.edit_backspace(s)
        end,
        ']' => function (s, args...)
            if isempty(s) || position(LineEdit.buffer(s)) == 0
                LineEdit.transition(s, pkg_mode)
            else
                LineEdit.edit_insert(s, ']')
            end
        end,
        '?' => function (s, args...)
            if isempty(s) || position(LineEdit.buffer(s)) == 0
                buf = copy(LineEdit.buffer(s))
                LineEdit.transition(s, help_mode) do
                    LineEdit.state(s, help_mode).input_buffer = buf
                end
            else
                LineEdit.edit_insert(s, '?')
            end
        end,
        ',' => function (s, args...)
            if isempty(s) || position(LineEdit.buffer(s)) == 0
                buf = copy(LineEdit.buffer(s))
                LineEdit.transition(s, main_mode) do
                    LineEdit.state(s, main_mode).input_buffer = buf
                end
            else
                LineEdit.edit_insert(s, ',')
            end
        end,
        "\x03" => function (s, args...)
            print(LineEdit.terminal(s), "^C\n\n")
            LineEdit.transition(s, julsh)
            LineEdit.transition(s, :reset)
            LineEdit.refresh_line(s)
        end,
    ))

    main_mode.keymap_dict['\b'] = function (s, args...)
        if isempty(s) || position(LineEdit.buffer(s)) == 0
            buf = copy(LineEdit.buffer(s))
            LineEdit.transition(s, julsh) do
                LineEdit.state(s, julsh).input_buffer = buf
            end
        else
            LineEdit.edit_backspace(s)
        end
    end

    pkg_mode.keymap_dict = LineEdit.keymap_merge(pkg_mode.keymap_dict, Dict{Any, Any}(
        '\b' => function (s, args...)
            if isempty(s) || position(LineEdit.buffer(s)) == 0
                buf = copy(LineEdit.buffer(s))
                LineEdit.transition(s, julsh) do
                    LineEdit.state(s, julsh).input_buffer = buf
                end
            else
                LineEdit.edit_backspace(s)
            end
        end,
        "\x03" => function (s, args...)
            print(LineEdit.terminal(s), "^C\n\n")
            LineEdit.transition(s, julsh)
            LineEdit.transition(s, :reset)
            LineEdit.refresh_line(s)
        end,
    ))

    help_mode.keymap_dict = LineEdit.keymap_merge(help_mode.keymap_dict, Dict{Any, Any}(
        '\b' => function (s, args...)
            if isempty(s) || position(LineEdit.buffer(s)) == 0
                buf = copy(LineEdit.buffer(s))
                LineEdit.transition(s, julsh) do
                    LineEdit.state(s, julsh).input_buffer = buf
                end
            else
                LineEdit.edit_backspace(s)
            end
        end,
        "\x03" => function (s, args...)
            print(LineEdit.terminal(s), "^C\n\n")
            LineEdit.transition(s, julsh)
            LineEdit.transition(s, :reset)
            LineEdit.refresh_line(s)
        end,
    ))

    help_mode.on_done = function (s, buf, ok::Bool)
        if !ok
            return LineEdit.transition(s, :abort)
        end
        line = String(take!(buf)::Vector{UInt8})
        f = line->REPL.helpmode(REPL.outstream(repl), line)
        ast = Base.invokelatest(f, line)
        response = REPL.eval_with_backend(ast, REPL.backend(repl))
        REPL.print_response(repl, response, true, REPL.hascolor(repl))
        println()
        return LineEdit.transition(s, julsh)
    end

    repl.interface.modes[1] = julsh
end

end # module
