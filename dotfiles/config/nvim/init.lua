-- Neovim, one file, no plugin manager. Read from ~/.config/nvim/init.lua.
--
-- Everything here is core Neovim 0.10+: options, filetype detection for the
-- files a DevOps repository is made of, and a few keymaps. Defaults and
-- built-in detection were checked against runtime/doc/vim_diff.txt and
-- runtime/lua/vim/filetype.lua; the vim.filetype.add block only adds what
-- Neovim does not detect on its own (Helm templates, .env variants,
-- Jenkinsfile.* and *.tpl, which otherwise maps to smarty).

vim.g.mapleader = ' '
vim.g.maplocalleader = ' '

-------------------------------------------------------------------------------
-- Options
-------------------------------------------------------------------------------
local o = vim.opt

o.number = true            -- absolute on the cursor line,
o.relativenumber = true    -- relative elsewhere: 5j and 3dd without counting
o.cursorline = true

o.expandtab = true         -- spaces, never tabs: YAML forbids them, HCL and Helm use spaces
o.shiftwidth = 2           -- the convention for YAML, HCL, Helm, JSON and Groovy
o.tabstop = 2
o.softtabstop = 2
o.smartindent = true
o.breakindent = true       -- wrapped lines keep their indent, so wrapped YAML stays readable

o.ignorecase = true        -- /configmap finds ConfigMap,
o.smartcase = true         -- /ConfigMap is exact: the same rule as rg --smart-case
o.inccommand = 'split'     -- live preview of :%s in a split; bulk YAML edits need it

o.undofile = true          -- undo survives closing the file (~/.local/state/nvim/undo)
o.swapfile = false         -- E325 prompts on a shared host are all swap files ever brought
o.writebackup = false      -- no "file changed on disk" churn with hot-reloading tools

o.clipboard = 'unnamedplus' -- yank and paste go through the system clipboard; OSC 52 over ssh
o.signcolumn = 'yes'       -- reserve the column so text does not jump when diagnostics appear
o.termguicolors = true
o.splitright = true
o.splitbelow = true
o.scrolloff = 8            -- eight lines of context above and below the cursor
o.sidescrolloff = 8
o.wrap = false             -- log and JSON lines do not wrap; <leader>tw toggles it
o.linebreak = true
o.updatetime = 250         -- CursorHold fires sooner than the default 4000ms
o.timeoutlen = 400
o.confirm = true           -- ask to save instead of failing :q on a modified buffer
o.mouse = 'a'
o.showmode = false
o.list = true              -- a stray tab in YAML is visible
o.listchars = { tab = '» ', trail = '·', nbsp = '␣', extends = '›', precedes = '‹' }
o.colorcolumn = '120'
o.completeopt = { 'menu', 'menuone', 'noselect' }
o.wildmode = { 'longest:full', 'full' }
o.wildignore:append({ '*/.git/*', '*/node_modules/*', '*/.terraform/*', '*.tfstate', '*.tfstate.backup' })
o.exrc = false             -- never auto-source a .nvim.lua from a cloned repository
o.grepprg = 'rg --vimgrep --smart-case --hidden' -- :grep is ripgrep and honours its config
o.grepformat = '%f:%l:%c:%m'
o.diffopt:append({ 'linematch:60', 'algorithm:histogram' })

-------------------------------------------------------------------------------
-- Filetype detection Neovim does not ship
-------------------------------------------------------------------------------
vim.filetype.add({
  extension = {
    gotmpl = 'helm',
    jenkinsfile = 'groovy',
    tpl = 'helm', -- built-in maps *.tpl to smarty; in an ops repository it is Helm
  },
  filename = {
    ['helmfile.yaml'] = 'helm',
    ['helmfile.yml'] = 'helm',
    ['.envrc'] = 'sh', -- direnv files are shell, not dotenv
    ['.terraform.lock.hcl'] = 'hcl',
    ['kubeconfig'] = 'yaml',
  },
  pattern = {
    -- Helm chart templates: Go templates inside YAML.
    ['.*/templates/.*%.ya?ml'] = { 'helm', { priority = 10 } },
    ['.*/templates/.*%.tpl'] = { 'helm', { priority = 10 } },
    ['.*/templates/NOTES%.txt'] = 'helm',
    ['.*/helmfile%.d/.*%.ya?ml'] = 'helm',
    ['Jenkinsfile%..*'] = 'groovy',
    ['.*%.jenkinsfile'] = 'groovy',
    -- .env.local, .env.production, .env.ci: shell highlighting on every version
    ['%.env%..*'] = 'sh',
    ['.*/%.env%..*'] = 'sh',
    ['.*/%.kube/config%..*'] = 'yaml',
    ['.*/kubeconfig.*'] = 'yaml',
    ['.*%.ya?ml%.j2'] = 'yaml',
  },
})

-------------------------------------------------------------------------------
-- Per-filetype indentation and borrowed syntax
-------------------------------------------------------------------------------
local aug = vim.api.nvim_create_augroup('devops_filetypes', { clear = true })

local function ft(patterns, fn)
  vim.api.nvim_create_autocmd('FileType', { group = aug, pattern = patterns, callback = fn })
end

-- Two spaces, stated per filetype because an ftplugin may override the global.
ft({ 'yaml', 'helm', 'json', 'jsonc', 'terraform', 'terraform-vars', 'hcl', 'groovy',
  'lua', 'sh', 'bash', 'zsh', 'toml', 'dockerfile', 'jinja' }, function()
  vim.bo.shiftwidth, vim.bo.tabstop, vim.bo.softtabstop, vim.bo.expandtab = 2, 2, 2, true
end)

-- PEP 8.
ft({ 'python' }, function()
  vim.bo.shiftwidth, vim.bo.tabstop, vim.bo.softtabstop, vim.bo.expandtab = 4, 4, 4, true
end)

-- Go and Makefiles need real tabs.
ft({ 'go', 'make' }, function()
  vim.bo.expandtab = false
  vim.bo.shiftwidth, vim.bo.tabstop = 4, 4
end)

-- YAML: never re-indent after a colon or a dash.
ft({ 'yaml', 'helm' }, function()
  vim.opt_local.indentkeys:remove({ '0#', '<:>' })
  vim.bo.smartindent = false
end)

-- Neovim ships no syntax for terraform-vars or helm; borrow the nearest.
ft({ 'terraform-vars' }, function()
  vim.bo.syntax = 'terraform'
  vim.bo.commentstring = '# %s'
end)
ft({ 'helm' }, function()
  vim.bo.syntax = 'yaml'
  vim.bo.commentstring = '{{/* %s */}}'
end)
ft({ 'terraform', 'hcl' }, function() vim.bo.commentstring = '# %s' end)
ft({ 'groovy' }, function() vim.bo.commentstring = '// %s' end)

-------------------------------------------------------------------------------
-- Trailing whitespace: shown always, stripped on save except where it means something
-------------------------------------------------------------------------------
vim.api.nvim_set_hl(0, 'ExtraWhitespace', { bg = '#b03030' })
vim.api.nvim_create_autocmd({ 'BufWinEnter', 'InsertLeave' }, {
  group = aug,
  callback = function()
    if vim.bo.buftype ~= '' then return end
    vim.fn.matchadd('ExtraWhitespace', [[\s\+$]])
  end,
})
vim.api.nvim_create_autocmd('BufWritePre', {
  group = aug,
  callback = function()
    -- Markdown uses a trailing double space for a line break; a patch is exact bytes.
    if vim.tbl_contains({ 'markdown', 'diff', 'gitcommit' }, vim.bo.filetype) then return end
    local view = vim.fn.winsaveview()
    vim.cmd([[keeppatterns %s/\s\+$//e]])
    vim.fn.winrestview(view)
  end,
})

-- Reload a file another tool changed: kubectl edit, git checkout, terraform fmt.
vim.api.nvim_create_autocmd({ 'FocusGained', 'BufEnter', 'CursorHold' }, {
  group = aug, command = 'silent! checktime',
})

-- Flash what was yanked. vim.hl is 0.11; vim.highlight is the 0.10 name.
vim.api.nvim_create_autocmd('TextYankPost', {
  group = aug,
  callback = function() (vim.hl or vim.highlight).on_yank({ timeout = 150 }) end,
})

-- Reopen a file where it was left.
vim.api.nvim_create_autocmd('BufReadPost', {
  group = aug,
  callback = function()
    local mark = vim.api.nvim_buf_get_mark(0, '"')
    if mark[1] > 0 and mark[1] <= vim.api.nvim_buf_line_count(0) then
      pcall(vim.api.nvim_win_set_cursor, 0, mark)
    end
  end,
})

-------------------------------------------------------------------------------
-- Keymaps
-------------------------------------------------------------------------------
local map = vim.keymap.set

map('n', '<Esc>', '<cmd>nohlsearch<CR>', { desc = 'Clear search highlight' })
map('n', '<leader>w', '<cmd>write<CR>', { desc = 'Save' })
map('n', '<leader>q', '<cmd>quit<CR>', { desc = 'Quit' })

-- Windows without the <C-w> chord.
map('n', '<C-h>', '<C-w>h')
map('n', '<C-j>', '<C-w>j')
map('n', '<C-k>', '<C-w>k')
map('n', '<C-l>', '<C-w>l')

-- Keep the selection while indenting a YAML block.
map('v', '<', '<gv')
map('v', '>', '>gv')

-- Move lines: reordering list items.
map('v', 'J', ":m '>+1<CR>gv=gv", { silent = true })
map('v', 'K', ":m '<-2<CR>gv=gv", { silent = true })

-- Stay centred after half-page jumps and search hits.
map('n', '<C-d>', '<C-d>zz')
map('n', '<C-u>', '<C-u>zz')
map('n', 'n', 'nzzzv')
map('n', 'N', 'Nzzzv')

-- Paste over a selection without losing the clipboard; delete to nowhere.
map('x', '<leader>p', [["_dP]], { desc = 'Paste without yanking' })
map({ 'n', 'v' }, '<leader>d', [["_d]], { desc = 'Delete without yanking' })

-- Toggles.
map('n', '<leader>tw', function() vim.wo.wrap = not vim.wo.wrap end, { desc = 'Toggle wrap' })
map('n', '<leader>tn', function() vim.wo.relativenumber = not vim.wo.relativenumber end,
  { desc = 'Toggle relative numbers' })
map('n', '<leader>ts', function() vim.wo.spell = not vim.wo.spell end, { desc = 'Toggle spell' })

-- ripgrep into the quickfix list.
map('n', '<leader>/', ':silent grep! ', { desc = 'ripgrep into quickfix' })
map('n', ']q', '<cmd>cnext<CR>')
map('n', '[q', '<cmd>cprev<CR>')

-- Run the buffer through the right formatter, in place.
map('n', '<leader>ft', '<cmd>!terraform fmt %<CR>', { desc = 'terraform fmt' })
map('n', '<leader>fy', '<cmd>%!yq -P .<CR>', { desc = 'Reformat YAML with yq' })
map('n', '<leader>fj', '<cmd>%!jq .<CR>', { desc = 'Reformat JSON with jq' })
map('n', '<leader>fb', '<cmd>%!base64 -d<CR>', { desc = 'base64-decode the buffer (Secrets)' })

-- Which filetype was detected, and why.
map('n', '<leader>fi', function()
  vim.print({ filetype = vim.bo.filetype, syntax = vim.bo.syntax, match = vim.filetype.match({ buf = 0 }) })
end, { desc = 'Filetype info' })
