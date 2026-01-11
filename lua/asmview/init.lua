--
local M = {}

local ns = vim.api.nvim_create_namespace("asmview_hl")

local state = {
        buf = nil,
        win = nil,
        mapping = {}, -- mapping[file_key][line] = { asm_line1, asm_line2, ... }
        last_key = nil,
        last_line = nil,
        cfg = nil,
}

local defaults = {
        -- 1. build step (Commands to build the kernel.elf)
        make_cmd = { "make", "-s", "hw" },

        -- 2. objdump step
        elf_path = "build/kernel.elf", -- path to the .elf file our build step generated
        objdump_cmd = { "arm-none-eabi-objdump" }, -- decompile argument
        objdump_args = { "-d", "-l", "--demangle", "--no-show-raw-insn" },

        -- UI
        split = "vert rightbelow vsplit",
        title = "AsmView",
        filetype = "asm",
        hl_group = "Visual",
        max_line_delta = 80, -- how far we search if exact :line isn't present

        -- behavior
        auto_sync = true, -- highlight follows cursor
}

local function notify(msg, level)
        vim.notify(msg, level or vim.log.levels.INFO, { title = "AsmView" })
end

local function get_root()
        local buf = vim.api.nvim_get_current_buf()
        local path = vim.api.nvim_buf_get_name(buf)
        if path == "" then
                return vim.fn.getcwd()
        end

        -- try modern root resolution
        if vim.fs and vim.fs.root then
                local root = vim.fs.root(path, { "Makefile", "compile_commands.json", ".git" })
                if root then
                        return root
                end
        end

        -- fallback: cwd
        return vim.fn.getcwd()
end

local function realpath(p)
        local uv = vim.uv or vim.loop
        if uv and uv.fs_realpath then
                return uv.fs_realpath(p) or p
        end
        return p
end

local function ensure_view()
        -- buffer
        local src_win = vim.api.nvim_get_current_win() -- remember current window
        if not (state.buf and vim.api.nvim_buf_is_valid(state.buf)) then
                state.buf = vim.api.nvim_create_buf(false, true) -- scratch
                vim.api.nvim_buf_set_name(state.buf, state.cfg.title)
                vim.bo[state.buf].buftype = "nofile"
                vim.bo[state.buf].bufhidden = "hide"
                vim.bo[state.buf].swapfile = false
                vim.bo[state.buf].modifiable = false
                vim.bo[state.buf].filetype = state.cfg.filetype
                vim.b[state.buf].asmview = true
        end

        -- window
        if not (state.win and vim.api.nvim_win_is_valid(state.win)) then
                vim.cmd(state.cfg.split)
                state.win = vim.api.nvim_get_current_win()
                vim.api.nvim_win_set_buf(state.win, state.buf)
                vim.wo[state.win].wrap = false
                vim.wo[state.win].number = false
                vim.wo[state.win].relativenumber = false
                vim.wo[state.win].cursorline = true
                vim.wo[state.win].signcolumn = "yes"
                pcall(vim.api.nvim_set_current_win, src_win)
        else
                -- ensure correct buffer
                if vim.api.nvim_win_get_buf(state.win) ~= state.buf then
                        vim.api.nvim_win_set_buf(state.win, state.buf)
                end
        end
end

local function close_view()
        if state.win and vim.api.nvim_win_is_valid(state.win) then
                pcall(vim.api.nvim_win_close, state.win, true)
        end
        state.win = nil
end

local function parse_objdump(lines, root)
        local display = {}
        local mapping = {}

        local current_file = nil
        local current_line = nil

        local function add_map(filekey, lnum, asm_lnum)
                mapping[filekey] = mapping[filekey] or {}
                mapping[filekey][lnum] = mapping[filekey][lnum] or {}
                table.insert(mapping[filekey][lnum], asm_lnum)
        end

        for _, line in ipairs(lines) do
                if not line or line == "" then
                        table.insert(display, "")
                        goto continue
                end

                -- source marker: /path/to/file.c:123  (also allow relative paths)
                local f, l = line:match("^(.+):(%d+)%s*$")
                if
                        f
                        and l
                        and (f:find("%.c$") or f:find("%.h$") or f:find("%.S$") or f:find("%.s$") or f:find("%.cpp$"))
                then
                        current_file = f
                        current_line = tonumber(l)
                        goto continue
                end

                -- function label: 000083b4 <foo>:
                if line:match("^%x+%s+<[^>]+>:%s*$") then
                        table.insert(display, line)
                        goto continue
                end

                -- assembly instruction: "   83c4:  cpsid if"
                if line:match("^%s*%x+:%s+") then
                        table.insert(display, line)
                        local asm_lnum = #display
                        if current_file and current_line then
                                -- normalize multiple keys (abs/real/relative/basename)
                                local abs = current_file
                                if not abs:match("^/") then
                                        abs = root .. "/" .. abs
                                end
                                local rp = realpath(abs)
                                local base = vim.fn.fnamemodify(abs, ":t")

                                add_map(rp, current_line, asm_lnum)
                                add_map(abs, current_line, asm_lnum)
                                add_map(base, current_line, asm_lnum)
                        end
                        goto continue
                end

                -- ignore other noise (like "foo():" lines etc.)
                ::continue::
        end

        return display, mapping
end

local function set_buffer_lines(lines)
        vim.bo[state.buf].modifiable = true
        vim.api.nvim_buf_set_lines(state.buf, 0, -1, false, lines)
        vim.bo[state.buf].modifiable = false
end

local function find_best_mapping(filekeys, line)
        for _, key in ipairs(filekeys) do
                local m = state.mapping[key]
                if m then
                        if m[line] then
                                return key, line, m[line]
                        end
                        -- nearest line search
                        local maxd = state.cfg.max_line_delta
                        for d = 1, maxd do
                                if m[line - d] then
                                        return key, line - d, m[line - d]
                                end
                                if m[line + d] then
                                        return key, line + d, m[line + d]
                                end
                        end
                end
        end
        return nil
end

function M.sync()
        if not (state.win and vim.api.nvim_win_is_valid(state.win)) then
                return
        end

        local src_buf = vim.api.nvim_get_current_buf()

        if src_buf == state.buf or vim.b[src_buf].asmview then
                return
        end

        local ft = vim.bo[src_buf].filetype
        if ft ~= "c" and ft ~= "cpp" and ft ~= "objc" and ft ~= "asm" and ft ~= "gas" then
                return
        end

        local file = vim.api.nvim_buf_get_name(src_buf)
        if file == "" then
                return
        end

        local line = vim.fn.line(".")
        local rp = realpath(file)
        local base = vim.fn.fnamemodify(file, ":t")

        local keys = { rp, file, base }

        local key, best_line, asm_lines = find_best_mapping(keys, line)
        if not asm_lines then
                return
        end

        -- avoid re-highlighting same thing constantly
        if state.last_key == key and state.last_line == best_line then
                return
        end
        state.last_key = key
        state.last_line = best_line

        -- clear previous highlights
        vim.api.nvim_buf_clear_namespace(state.buf, ns, 0, -1)

        local hl = (vim.fn.hlexists(state.cfg.hl_group) == 1) and state.cfg.hl_group or "Search"

        -- highlight all asm lines that correspond to this C line
        for _, lnum in ipairs(asm_lines) do
                vim.api.nvim_buf_set_extmark(state.buf, ns, lnum - 1, 0, {
                        line_hl_group = hl,
                        sign_text = "▶",
                        sign_hl_group = hl,
                        priority = 200,
                })
        end

        local first = asm_lines[1]
        local src_win = vim.api.nvim_get_current_win()
        vim.api.nvim_win_call(state.win, function()
                pcall(vim.api.nvim_win_set_cursor, state.win, { first, 0 })
                vim.cmd("normal! zz")
        end)
        vim.api.nvim_set_current_win(src_win)
end

-- small debounce so CursorMoved doesn't spam
local sync_token = 0
local function debounced_sync()
        sync_token = sync_token + 1
        local t = sync_token
        vim.defer_fn(function()
                if t == sync_token then
                        pcall(M.sync)
                end
        end, 30)
end

function M.rebuild()
        local root = get_root()
        ensure_view()

        local make_cmd = state.cfg.make_cmd
        local elf = state.cfg.elf_path

        notify("Building…", vim.log.levels.INFO)

        vim.fn.jobstart(make_cmd, {
                cwd = root,
                stdout_buffered = true,
                stderr_buffered = true,
                on_exit = function(_, code)
                        if code ~= 0 then
                                notify("make failed (see :messages)", vim.log.levels.ERROR)
                                return
                        end

                        local objdump_cmd = vim.deepcopy(state.cfg.objdump_cmd)
                        local args = vim.deepcopy(state.cfg.objdump_args)
                        table.insert(args, elf)

                        local cmd = vim.list_extend(objdump_cmd, args)

                        vim.fn.jobstart(cmd, {
                                cwd = root,
                                stdout_buffered = true,
                                stderr_buffered = true,
                                on_stdout = function(_, data)
                                        -- data is delivered in chunks; we buffer in on_exit via vim.v.shell_error? easier: collect here
                                end,
                                on_exit = function(_, code2)
                                        if code2 ~= 0 then
                                                notify(
                                                        "objdump failed (is it in PATH? set objdump_cmd)",
                                                        vim.log.levels.ERROR
                                                )
                                                return
                                        end

                                        -- Re-run objdump synchronously to collect stdout reliably (still fast)
                                        local out = vim.fn.systemlist(table.concat(cmd, " "), root)
                                        local display, mapping = parse_objdump(out, root)

                                        state.mapping = mapping
                                        set_buffer_lines(display)

                                        notify("Asm updated", vim.log.levels.INFO)
                                        pcall(M.sync)
                                end,
                        })
                end,
        })
end

function M.open()
        ensure_view()
        M.rebuild()
end

function M.toggle()
        if state.win and vim.api.nvim_win_is_valid(state.win) then
                close_view()
        else
                M.open()
        end
end

function M.setup(opts)
        state.cfg = vim.tbl_deep_extend("force", defaults, opts or {})

        vim.api.nvim_create_user_command("AsmViewToggle", function()
                M.toggle()
        end, {})
        vim.api.nvim_create_user_command("AsmViewRebuild", function()
                M.rebuild()
        end, {})
        vim.api.nvim_create_user_command("AsmViewOpen", function()
                M.open()
        end, {})

        if state.cfg.auto_sync then
                vim.api.nvim_create_augroup("AsmViewSync", { clear = true })
                vim.api.nvim_create_autocmd({ "CursorMoved", "CursorMovedI", "CursorHold" }, {
                        group = "AsmViewSync",
                        callback = function()
                                if state.win and vim.api.nvim_win_is_valid(state.win) then
                                        debounced_sync()
                                end
                        end,
                })
        end
end

return M
