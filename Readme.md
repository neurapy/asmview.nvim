# asmview.nvim

I was very frustrated to not find this exact plugin online so i made it myself.
I hope this is exactly what you are looking for. :)

`asmview.nvim` is a tiny nvim plugin that opens a live “assembly view”
for your current project and keeps it synchronized with the
source line under the cursor. Right now it works with C/C++/ASM Code.

---
Image

## Features

- **Split view disassembly**: opens a dedicated scratch buffer showing `objdump`
output
- **Line mapping**: highlights the assembly instructions that correspond to the
current source line
- **Auto sync** (optional): highlight follows your cursor as you move through
the code
- Works with **C/C++/ObjC** and **assembly sources** like `.S` / `.s`
- Works with everything else too as long as debug line info is present in the
ELF and the file type is added to the source code. If anyone ever finds this, feel
free to add more.

---

## What it does

1. Builds your project with the `make_cmd` you set into a .elf (you specify the
path with `elf_path`)
2. Generates an objdump of that .elf using `objdump_cmd` and `objdump_args` you
provided and displays it next to your code

## Requirements

- A build that produces an ELF with **debug line information**
- `objdump` suitable for your target (e.g. `arm-none-eabi-objdump`)

> **Important:** The mapping relies on file:line markers from `objdump -l`.  
> If your build strips debug info or omits `-g`, mapping can be incomplete or missing.

---

## Installation

### lazy.nvim

`../nvim/lua/plugins/asmview.lua`

```lua
{
  "neurapy/asmview.nvim",
  cmd = { "AsmViewToggle", "AsmViewOpen", "AsmViewRebuild" },
  -- keymaps:
  keys = {
    { "<leader>od", "<cmd>AsmViewToggle<cr>", desc = "AsmView: toggle" },
    { "<leader>or", "<cmd>AsmViewRebuild<cr>", desc = "AsmView: rebuild" },
  },    
  opts = function()
    return require("config.asmview") -- ../nvim/lua/config/asmview.lua
  end,
}
```

## Configuration

`../nvim/lua/config/asmview.lua`

```lua

-- these match the plugin's defaults

return {
  -- 1) Build step (command that produces the ELF)
  make_cmd = { "make", "-s", "hw" },

  -- 2) objdump step
  elf_path = "build/kernel.elf", -- relative to project root
  objdump_cmd = { "arm-none-eabi-objdump" },
  objdump_args = { -- if you remove these it will break.
    "-d",                 -- disassemble
    "-l",                 -- include file:line info (required for mapping)
    "--demangle",         -- nicer symbols (useful for C++)
    "--no-show-raw-insn", -- hide raw bytes
  },

  -- UI
  split = "vert rightbelow vsplit",
  title = "AsmView",
  filetype = "asm", -- the type the AMSVIEW BUFFER is treated at
  hl_group = "Visual",
  max_line_delta = 80,

  -- behavior
  auto_sync = true,
}
```
