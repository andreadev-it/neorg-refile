local neorg = require('neorg.core')

local module = neorg.modules.create('external.refiling')

---@class Target
---@field file string
---@field heading_title string
---@field heading_level number

module.setup = function()
    return {
        requires = {
            'core.esupports.hop',
            'core.esupports.indent',
            'core.neorgcmd',
            'core.dirman',
            'core.queries.native'
        }
    }
end

module.load = function()
    module.required['core.neorgcmd'].add_commands_from_table({
        refile = {
            args = 0,
            name = "external.refiling.refile",
            condition = "norg"
        }
    })
end

module.public = {
    ---Refile the node under the cursor under the given target. It asks for
    ---a target using telescope if nil is given
    ---@param target any
    refile_under_cursor = function(target)
        -- Get node under cursor
        local cur_node = vim.treesitter.get_node()

        if cur_node == nil then
            print("There is no refilable node under cursor. This function should be used on list items or under headings.")
            return
        end

        local node = module.private.get_refilable_node(cur_node)

        if node == nil then
            print("No heading or list item found under cursor")
            return
        end

        if target == nil then
            module.private.get_target_from_telescope(function (selection)
                -- count the amount of "*" at the beginning of the string
                local level = #selection.text:match(module.config.private.patterns.heading_prefix)
                local title = selection.text:match(module.config.private.patterns.heading_title)

                ---@type Target
                target = {
                    file = selection.filename,
                    heading_title = title,
                    heading_level = level
                }

                module.public.refile(node, target)
            end)

            return
        end

        module.public.refile(node, target)
    end,

    ---Refile a node under a different file, in a specific heading
    ---@param node TSNode
    ---@param target Target
    refile = function(node, target)

        -- Get the text from the node
        local origin_buf = vim.api.nvim_get_current_buf()
        local text = vim.treesitter.get_node_text(node, origin_buf)

        module.public.refile_text(text, target)

        -- Remove the text from the source file
        local start_row, _, end_row, end_col = vim.treesitter.get_node_range(node)

        -- Fix ranges that end on the next line (has problems otherwise)
        if end_col == 0 then
            end_row = end_row - 1
        end

        vim.api.nvim_buf_set_lines(origin_buf, start_row, end_row + 1, false, {})
    end,

    ---Refile a given text into a new file, under a specific heading
    ---@param text string
    ---@param target Target
    refile_text = function(text, target)
        -- Get a reference to the target file in the correct position
        -- Here we should be able to use a function from the hop module,
        -- probably locate_link_target
        local buf = module.private.open_buffer_bg(target.file)

        local headings = module.private.get_buffer_headlines(buf)

        local heading_info = module.private.find_target_header(headings, target, buf)

        if heading_info == nil then
            error("Could not find heading in target file")
            return
        end

        local node = heading_info[1]
        local level = heading_info[2]
        -- This is correct because the node is not the heading,
        -- but only the heading text (a paragraph_segment)
        local heading = module.private.get_parent_heading(node)

        if heading == nil then
            error("Could not find heading in target file. This shouldn't happen...")
            return
        end

        print("Refiling under heading '" .. vim.treesitter.get_node_text(heading, buf) .. "'")

        local start_row, _, end_row, _ = vim.treesitter.get_node_range(heading)

        -- Adjust the text heading levels
        local adjusted_text = module.public.adjust_headings(level, text)

        -- Actual refiling
        local text_lines = module.private.split_lines(adjusted_text)
        vim.api.nvim_buf_set_lines(buf, end_row, end_row, false, text_lines)

        module.required['core.esupports.indent'].reindent_range(buf, start_row, end_row + 1)

        -- Print a message to the user
        print("The text has been refiled to " .. target.file)
    end,

    ---Corrects the norg heading level
    ---@param base_level any
    ---@param text any
    adjust_headings = function (base_level, text)
        local lines = module.private.split_lines(text)
        ---@type [number, number][]
        local heading_indexes = {}
        local min_level = 100

        for i, row in ipairs(lines) do
            if string.match(row, module.config.private.patterns.heading_prefix) then
                local level = module.private.get_heading_level_from_string(row)

                table.insert(heading_indexes, {i, level})

                if level < min_level then
                    min_level = level
                end
            end
        end

        for _, details in ipairs(heading_indexes) do
            local index = details[1]
            local level = details[2]
            local asterisks_amount = base_level + (level - min_level + 1)

            local asterisks = string.rep("*", asterisks_amount, "")

            lines[index] = string.gsub(lines[index], module.config.private.patterns.heading_prefix, asterisks)
        end

        return table.concat(lines, "\n")
    end
}

module.config.private = {
    patterns = {
        heading_pattern = "^heading%d$",
        ordered_list_item_pattern = "^ordered_list%d$",
        unordered_list_item_pattern = "^unordered_list%d$",
        heading_prefix = "^%s*(%**)",
        heading_title = "%s*%**%s+(.*)$"
    }
}

module.private = {
    ---Find a refilable node looking at the parents of the node too
    ---@param node TSNode
    ---@return TSNode?
    get_refilable_node = function(node)
        local types_patterns = {
            module.config.private.patterns.heading_pattern,
            module.config.private.patterns.ordered_list_item_pattern,
            module.config.private.patterns.unordered_list_item_pattern
        }

        return module.private.get_parent_of_type(node, types_patterns)
    end,

    ---Check if a node is a refilable node (either an heading or a list item)
    ---@param node TSNode
    ---@return boolean
    is_refilable_node = function(node)
        local t = node:type()
        if t:find(module.config.private.patterns.heading_pattern)
            or t:find(module.config.private.patterns.ordered_list_item_pattern)
            or t:find(module.config.private.patterns.unordered_list_item_pattern)
        then
            return true
        end

        return false
    end,

    ---Get the heading that contains the node, if exists
    ---@param node any
    ---@return TSNode?
    get_parent_heading = function(node)
        local types_patterns = {
            module.config.private.patterns.heading_pattern
        }

        return module.private.get_parent_of_type(node, types_patterns)
    end,

    ---Get the list item that contains the node, if exists
    ---@param node any
    ---@return TSNode?
    get_parent_list_item = function(node)
        local types_patterns = {
            module.config.private.patterns.ordered_list_item_pattern,
            module.config.private.patterns.unordered_list_item_pattern
        }

        return module.private.get_parent_of_type(node, types_patterns)
    end,

    ---Get the parent of a node that matches one of the given type patterns
    ---@param node TSNode
    ---@param types string[] Patterns to check the type against
    ---@return TSNode?
    get_parent_of_type = function(node, types)
        ---@type TSNode?
        local cur = node

        while cur ~= nil do
            for _, value in ipairs(types) do
                if cur:type():find(value) then
                    return cur
                end
            end

            cur = cur:parent()
        end

        return nil
    end,

    ---Get the target from telescope
    ---@param callback function The callback that receives the selection as parameter
    get_target_from_telescope = function (callback)
        local success, actions = pcall(require, 'telescope.actions')

        if not success then
            print("Telescope is needed for this functionality")
            return
        end

        local action_state = require('telescope.actions.state')

        local run_selection = function (prompt_bufnr, map)
            actions.select_default:replace(function()
                actions.close(prompt_bufnr)
                local selection = action_state.get_selected_entry()
                callback(selection)
            end)
            return true
        end

        local current_workspace = module.required['core.dirman'].get_current_workspace()

        local opts = {
            search = "^\\s*(\\*+|\\|{1,2}|\\${1,2})\\s+",
            use_regex = true,
            search_dirs = { tostring(current_workspace[2]) },
            attach_mappings = run_selection
        }

        require('telescope.builtin').grep_string(opts)
    end,

    ---Get all headlines in a specific buffer, along with their
    ---heading level.
    ---@param bufnr number
    ---@return [TSNode, number][]
    get_buffer_headlines = function (bufnr)
        local tree = {
            {
                query = { "all", "heading1" },
                subtree = {
                    { query = { "first", "paragraph_segment" } },
                },
                recursive = true
            },
            {
                query = { "all", "heading2" },
                subtree = {
                    { query = { "first", "paragraph_segment" } }
                },
                recursive = true
            },
            {
                query = { "all", "heading3" },
                subtree = {
                    { query = { "first", "paragraph_segment" } }
                },
                recursive = true
            },
            {
                query = { "all", "heading4" },
                subtree = {
                    { query = { "first", "paragraph_segment" } }
                },
                recursive = true
            },
            {
                query = { "all", "heading5" },
                subtree = {
                    { query = { "first", "paragraph_segment" } }
                },
                recursive = true
            },
            {
                query = { "all", "heading6" },
                subtree = {
                    { query = { "first", "paragraph_segment" } }
                },
                recursive = true
            },
            {
                query = { "all", "heading7" },
                subtree = {
                    { query = { "first", "paragraph_segment" } }
                },
                recursive = true
            },
        }

        ---@type table<TSNode, number>[]
        local nodes = module.required['core.queries.native'].query_nodes_from_buf(tree, bufnr)

        local headings = {}

        for _, node_buf in ipairs(nodes) do
            local node = node_buf[1]
            local level = module.private.get_heading_level(node)
            table.insert(headings, { node, level })
        end

        return headings
    end,

    ---Gets the heading level from the title text node
    ---@param node TSNode
    ---@return number
    get_heading_level = function (node)
        local parent = node:parent()

        if parent == nil then
            error("Something went wrong with the target heading. It seems the title node doesn't have a parent.")
        end

        local type = parent:type()

        if type:find(module.config.private.patterns.heading_pattern) == nil then
            error("The target node is not a heading. This shouldn't happen.")
        end

        local level = tonumber(type:gsub("heading", ""), 10)

        if level == nil then
            error("Could not detect the target heading level.")
        end

        return level
    end,

    ---Get the level of an heading line
    ---@param text any
    ---@return number
    get_heading_level_from_string = function (text)
        return #text:match(module.config.private.patterns.heading_prefix)
    end,

    ---Finds the requested header in the list of headers
    ---found in the target file.
    ---@param headings [TSNode, number][]
    ---@param target Target
    ---@return [TSNode, number]?
    find_target_header = function (headings, target, bufnr)
        for _, heading_info in ipairs(headings) do
            local node = heading_info[1]
            local level = heading_info[2]
            local title = vim.treesitter.get_node_text(node, bufnr)

            if title == target.heading_title and level == target.heading_level then
                return heading_info
            end
        end
    end,

    ---Open a file in an invisible new buffer
    ---@param file string
    ---@return integer
    open_buffer_bg = function (file)
        local buf = vim.fn.bufadd(file)
        vim.fn.bufload(buf)

        return buf
    end,

    ---Split a string into lines
    ---@param str string
    ---@return table<string>
    split_lines = function (str)
        local result = {}
        for line in str:gmatch('[^\n]+') do
            table.insert(result, line)
        end
        return result
    end
}


module.events.subscribed = {
    ['core.neorgcmd'] = {
        ['external.refiling.refile'] = true
    }
}

module.on_event = function (event)
    if event.split_type[2] == 'external.refiling.refile' then
        module.public.refile_under_cursor()
    end
end

return module
