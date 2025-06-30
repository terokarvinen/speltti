VERSION = "0.0.1"
-- https://terokarvinen.com/speltti
-- Copyright 2025 Tero Karvinen https://TeroKarvinen.com
-- Forked from Priner et al micro-aspell-plugin
-- MIT License

local micro = import("micro")
local shell = import("micro/shell")
local buffer = import("micro/buffer")
local config = import("micro/config")
local util = import("micro/util")
local utf = import("unicode/utf8")
local time = import("time")

config.RegisterCommonOption("speltti", "check", "auto")
config.RegisterCommonOption("speltti", "lang", "")
config.RegisterCommonOption("speltti", "dict", "")
config.RegisterCommonOption("speltti", "sugmode", "normal")
config.RegisterCommonOption("speltti", "args", "")

function init()
    config.MakeCommand("addpersonal", addpersonal, config.NoComplete)
    config.MakeCommand("acceptsug", acceptsug, config.NoComplete)
    config.MakeCommand("togglecheck", togglecheck, config.NoComplete)
    config.AddRuntimeFile("speltti", config.RTHelp, "help/speltti.md")
end

local filterModes = {
    xml = "sgml",
    ["c++"] = "ccpp",
    c = "ccpp",
    html = "html",
    html4 = "html",
    html5 = "html",
    perl = "perl",
    perl6 = "perl",
    tex = "tex",
    markdown = "markdown",
    groff = "nroff",
    man = "nroff",
    ["git-commit"] = "url",
    mail = "email"
    -- Aspell has comment mode, in which only lines starting with # are checked
    -- but it doesn't work for some reason
}

local lock = false
local next = nil
local lastActivityTime = 0
local idleTimeoutMs = 500 -- 0.5 seconds in milliseconds
local lastCursorLine = -1
local currentBufPane = nil

function runAspell(buf, onExit, bp, ...)
    local options = {"pipe", "--encoding=utf-8"}
    if filterModes[buf:FileType()] then
        options[#options + 1] = "--mode=" .. filterModes[buf:FileType()]
    end
    if buf.Settings["speltti.lang"] ~= "" then
        options[#options + 1] = "--lang=" .. buf.Settings["speltti.lang"]
    end
    if buf.Settings["speltti.dict"] ~= "" then
        options[#options + 1] = "--master=" .. buf.Settings["speltti.dict"]
    end
    if buf.Settings["speltti.sugmode"] ~= "" then
        options[#options + 1] = "--sug-mode=" .. buf.Settings["speltti.sugmode"]
    end
    for _, argument in ipairs(split(buf.Settings["speltti.args"], " ")) do
        options[#options + 1] = argument
    end

    -- Get visible area from buffer pane
    local startline = 0
    local endline = buf:LinesNum() - 1
    if bp then
        local bufwindow = bp:GetView()
        startline = bufwindow.StartLine.Line
        local height = bufwindow.Height
        endline = startline + height - 1
        -- Ensure we don't go beyond the buffer length
        if endline >= buf:LinesNum() then
            endline = buf:LinesNum() - 1
        end
    end
    
    -- Calculate number of lines checked
    local linesChecked = endline - startline + 1

    local job = shell.JobSpawn("aspell", options, nil,
            nil, onExit, buf, bp, linesChecked, unpack(arg))
    -- Enable terse mode
    shell.JobSend(job, "!\n")
    
    -- Send empty lines for lines before visible area
    for i = 0, startline - 1 do
        shell.JobSend(job, "^\n")
    end
    
    -- Send visible lines
    for i = startline, endline do
        local line = util.String(buf:LineBytes(i))
        -- Escape for aspell (it interprets lines that start
        -- with % @ ^ ! etc.)
        line = "^" .. line .. "\n"
        shell.JobSend(job, line)
    end
    
    -- Send empty lines for lines after visible area
    for i = endline + 1, buf:LinesNum() - 1 do
        shell.JobSend(job, "^\n")
    end
    
    job.Stdin:Close()
end

function spellcheck(buf, bp)
    local check = buf.Settings["speltti.check"]
    local readcheck = buf.Type.Readonly
    if (check == "on" or (check == "auto" and filterModes[buf:FileType()])) and (not readcheck) then
        if lock then
            next = {buf, bp}
        else
            lock = true
            -- micro.InfoBar():Message("Spellcheck started...")
            runAspell(buf, highlight, bp)
        end
    else
        -- If we aren't supposed to spellcheck, clear the messages
        buf:ClearMessages("speltti")
    end
end

function getCurrentTimeMs()
    return time.Now():UnixNano() / 1000000
end

function spellcheckDelayed(buf, bp)
    -- Record the current time as the last activity
    lastActivityTime = getCurrentTimeMs()
    
    -- Set up a timer to check if we're still idle after the timeout
    micro.After(time.Millisecond * 100, function()
        checkIdleAndSpell(buf, bp)
    end)
end

function updateCursorTracking(buf, bp)
    -- Update cursor position tracking without triggering spell check
    -- Let the periodic monitor handle spell checking
    if bp then
        currentBufPane = bp
        lastCursorLine = bp.Cursor.Y
    end
end

function startCursorMonitoring()
    -- Check cursor position periodically to catch goto operations
    micro.After(time.Millisecond * 200, function()
        checkCursorPosition()
    end)
end

function checkCursorPosition()
    -- Get current active pane directly from micro
    local bp = micro.CurPane()
    if bp and bp.Cursor then
        local currentLine = bp.Cursor.Y
        if currentLine ~= lastCursorLine then
            lastCursorLine = currentLine
            spellcheckDelayed(bp.Buf, bp)
        end
    end
    
    -- Schedule next check
    micro.After(time.Millisecond * 1000, function()
        checkCursorPosition()
    end)
end

function checkIdleAndSpell(buf, bp)
    local currentTime = getCurrentTimeMs()
    local timeSinceActivity = currentTime - lastActivityTime
    
    if timeSinceActivity >= idleTimeoutMs then
        -- We've been idle long enough, show idle message and do the spell check
        -- micro.InfoBar():Message("Idle")
        spellcheck(buf, bp)
    else
        -- Still not idle enough, check again later
        local remainingTime = idleTimeoutMs - timeSinceActivity
        local checkDelay = math.min(remainingTime + 100, 1000) -- Check again in up to 1 second
        micro.After(time.Millisecond * checkDelay, function()
            checkIdleAndSpell(buf, bp)
        end)
    end
end

-- Parses the output of Aspell and returns the list of all misspells.
function parseOutput(out)
    local patterns = {"^# (.-) (%d+)$", "^& (.-) %d+ (%d+): (.+)$"}

    if out:find("command not found") then
        micro.InfoBar():Error(
                "Make sure that Aspell is installed and available in your PATH")
        return {}
    elseif not out:find("International Ispell Version") then
        -- Something went wrong, we'll show what Aspell has to say
        micro.InfoBar():Error("Aspell: " .. out)
        return {}
	-- else
    --    micro.InfoBar():Message("Speltti: found aspell.")
    end

    local misspells = {}

    local linenumber = 1
    local lines = split(out, "\n")
    for _, line in ipairs(lines) do
        if line == "" then
            linenumber = linenumber + 1
        else
            for _, pattern in ipairs(patterns) do
                if string.find(line, pattern) then
                    local word, offset, suggestions = string.match(line, pattern)
                    offset = tonumber(offset)
                    local len = utf.RuneCountInString(word)

                    misspells[#misspells + 1] = {
                        word = word,
                        mstart = buffer.Loc(offset - 1, linenumber - 1),
                        mend = buffer.Loc(offset - 1 + len, linenumber - 1),
                        suggestions = suggestions and split(suggestions, ", ") or {},
                    }
                end
            end
        end
    end

    return misspells
end

function highlight(out, args)
    local buf = args[1]
    local bp = args[2]
    local linesChecked = args[3] or 0

    buf:ClearMessages("speltti")

    -- This is a hack that keeps the text shifted two columns to the right
    -- even when no gutter messages are shown
    local msg = "This message shouldn't be visible (Speltti plugin)"
    local bmsg = buffer.NewMessageAtLine("speltti", msg, 0, buffer.MTError)
    buf:AddMessage(bmsg)

    for _, misspell in ipairs(parseOutput(out)) do
        local msg = nil
        if #(misspell.suggestions) > 0 then
            msg = misspell.word .. " -> " .. table.concat(misspell.suggestions, ", ")
        else
            msg = misspell.word .. " ->X"
        end
        local bmsg = buffer.NewMessage("speltti", msg, misspell.mstart,
                misspell.mend, buffer.MTWarning)
        buf:AddMessage(bmsg)
    end

    lock = false
    -- micro.InfoBar():Message("Spellcheck done. " .. linesChecked .. " lines checked.")
    if next ~= nil then
        spellcheck(next[1], next[2])
        next = nil
    end
end

function parseMessages(messages)
    local patterns = {"^(.-) %-> (.+)$", "^(.-) %->X$"}

    if messages == nil then
        return {}
    end

    local misspells = {}

    for i=1, #messages do
        local message = messages[i]
        if message.Owner == "speltti" then
            for _, pattern in ipairs(patterns) do
                if string.find(message.Msg, pattern) then
                    local word, suggestions = string.match(message.Msg, pattern)

                    misspells[#misspells + 1] = {
                        word = word,
                        mstart = -message.Start,
                        mend = -message.End,
                        suggestions = suggestions and split(suggestions, ", ") or {},
                    }
                end
            end
        end
    end

    return misspells
end

function togglecheck(bp, args)
	local buf = bp.Buf
	local check = buf.Settings["speltti.check"]
    if check == "on" or (check == "auto" and filterModes[buf:FileType()]) then
		buf.Settings["speltti.check"] = "off"
	else
		buf.Settings["speltti.check"] = "on"
	end
	spellcheck(buf, bp)
	if args then
        return
    end
    return true
end

function addpersonal(bp, args)
    local buf = bp.Buf

    local loc = buf:GetActiveCursor().Loc

    for _, misspell in ipairs(parseMessages(buf.Messages)) do
        local wordInBuf = util.String(buf:Substr(misspell.mstart, misspell.mend))
        if loc:GreaterEqual(misspell.mstart) and loc:LessEqual(misspell.mend)
                and wordInBuf == misspell.word then
            local options = {"pipe", "--encoding=utf-8"}
            if buf.Settings["speltti.lang"] ~= "" then
                options[#options + 1] = "--lang=" .. buf.Settings["speltti.lang"]
            end
            if buf.Settings["speltti.dict"] ~= "" then
                options[#options + 1] = "--master=" .. buf.Settings["speltti.dict"]
            end
            for _, argument in ipairs(split(buf.Settings["speltti.args"], " ")) do
                options[#options + 1] = argument
            end

            local job = shell.JobSpawn("aspell", options, nil, nil, function ()
                spellcheck(buf, bp)
            end)
            shell.JobSend(job, "*" .. misspell.word .. "\n#\n")
            job.Stdin:Close()

            if args then
                return
            end
            return true
        end
    end

    if args then
        return
    end
    return false
end

function acceptsug(bp, args)
    local buf = bp.Buf
    local n = nil
    if args and #args > 0 then
        n = tonumber(args[1])
    end

    local loc = buf:GetActiveCursor().Loc

    for _, misspell in ipairs(parseMessages(buf.Messages)) do
        local wordInBuf = util.String(buf:Substr(misspell.mstart, misspell.mend))
        if loc:GreaterEqual(misspell.mstart) and loc:LessEqual(misspell.mend)
                and wordInBuf == misspell.word then
            if misspell.suggestions[n] then
                -- If n is in the range we'll accept n-th suggestion
                buf:GetActiveCursor():GotoLoc(misspell.mend)
                buf:Replace(misspell.mstart, misspell.mend, misspell.suggestions[n])

                spellcheck(buf, bp)
                if args then
                    return
                end
                return true
            elseif #(misspell.suggestions) > 0 then
                -- If n is 0 indicating acceptsug was called with no arguments
                -- we will cycle through the suggestions autocomplete-like
                buf:GetActiveCursor():GotoLoc(misspell.mend)
                buf:Remove(misspell.mstart, misspell.mend)
                buf:Autocomplete(function ()
                    return misspell.suggestions, misspell.suggestions
                end)

                spellcheck(buf, bp)
                if args then
                    return
                end
                return true
            end
        end
    end

    if args then
        return
    end
    return false
end

function split(str, pat)
    local t = {}
    local fpat = "(.-)" .. pat
    local last_end = 1
    local s, e, cap = str:find(fpat, 1)
    while s do
        if s ~= 1 or cap ~= "" then
            table.insert(t, cap)
        end
        last_end = e+1
        s, e, cap = str:find(fpat, last_end)
    end
    if last_end <= #str then
        cap = str:sub(last_end)
        table.insert(t, cap)
    end
    return t
end

-- We need to spellcheck every time, the buffer is modified. Sadly there's
-- no such thing as onBufferModified()

function onBufferOpen(buf)
    -- No immediate spell checking to avoid slowing down file loading
end

function onBufPaneOpen(bp)
    -- Initialize gutter immediately to prevent text jumping
    local buf = bp.Buf
    local msg = "This message shouldn't be visible (Aspell plugin)"
    local bmsg = buffer.NewMessageAtLine("speltti", msg, 0, buffer.MTError)
    buf:AddMessage(bmsg)
    
    -- Initialize cursor line tracking and store current pane
    if bp then
        lastCursorLine = bp.Cursor.Y
        currentBufPane = bp
    end
    
    -- Start periodic cursor line monitoring
    startCursorMonitoring()
    
    -- Use delayed spell checking when buffer pane opens
    spellcheckDelayed(buf, bp)
end

-- The following callbacks are undocumented

function onRune(bp)
    -- Update current buffer pane reference and trigger spell check for typing
    currentBufPane = bp
    lastCursorLine = bp.Cursor.Y  -- Update line tracking for typing
    spellcheckDelayed(bp.Buf, bp)
end

function onCycleAutocompleteBack(bp)
    spellcheckDelayed(bp.Buf, bp)
end

-- The following were copied from help keybindings

function onCursorUp(bp)
    -- Arrow keys change cursor position, trigger spell check
    currentBufPane = bp
    lastCursorLine = bp.Cursor.Y
    spellcheckDelayed(bp.Buf, bp)
end

function onCursorDown(bp)
    -- Arrow keys change cursor position, trigger spell check
    currentBufPane = bp
    lastCursorLine = bp.Cursor.Y
    spellcheckDelayed(bp.Buf, bp)
end

function onCursorPageUp(bp)
    -- Page up/down keys change cursor and view, trigger spell check
    currentBufPane = bp
    lastCursorLine = bp.Cursor.Y
    spellcheckDelayed(bp.Buf, bp)
end

function onCursorPageDown(bp)
    -- Page up/down keys change cursor and view, trigger spell check
    currentBufPane = bp
    lastCursorLine = bp.Cursor.Y
    spellcheckDelayed(bp.Buf, bp)
end

-- function onCursorLeft(bp)
-- end

-- function onCursorRight(bp)
-- end

-- function onCursorStart(bp)
-- end

-- function onCursorEnd(bp)
-- end

-- function onSelectToStart(bp)
-- end

-- function onSelectToEnd(bp)
-- end

-- function onSelectUp(bp)
-- end

-- function onSelectDown(bp)
-- end

-- function onSelectLeft(bp)
-- end

-- function onSelectRight(bp)
-- end

-- function onSelectToStartOfText(bp)
-- end

-- function onSelectToStartOfTextToggle(bp)
-- end

-- function onWordRight(bp)
-- end

-- function onWordLeft(bp)
-- end

-- function onSelectWordRight(bp)
-- end

-- function onSelectWordLeft(bp)
-- end

function onMoveLinesUp(bp)
    spellcheckDelayed(bp.Buf, bp)
end

function onMoveLinesDown(bp)
    spellcheckDelayed(bp.Buf, bp)
end

function onDeleteWordRight(bp)
    spellcheckDelayed(bp.Buf, bp)
end

function onDeleteWordLeft(bp)
    spellcheckDelayed(bp.Buf, bp)
end

-- function onSelectLine(bp)
-- end

-- function onSelectToStartOfLine(bp)
-- end

-- function onSelectToEndOfLine(bp)
-- end

function onInsertNewline(bp)
    spellcheckDelayed(bp.Buf, bp)
end

function onInsertSpace(bp)
    spellcheckDelayed(bp.Buf, bp)
end

function onBackspace(bp)
    spellcheckDelayed(bp.Buf, bp)
end

function onDelete(bp)
    spellcheckDelayed(bp.Buf, bp)
end

-- function onCenter(bp)
-- end

function onInsertTab(bp)
    spellcheckDelayed(bp.Buf, bp)
end

-- function onSave(bp)
-- end

-- function onSaveAll(bp)
-- end

-- function onSaveAs(bp)
-- end

-- function onFind(bp)
-- end

-- function onFindLiteral(bp)
-- end

-- function onFindNext(bp)
-- end

-- function onFindPrevious(bp)
-- end

function onUndo(bp)
    spellcheckDelayed(bp.Buf, bp)
end

function onRedo(bp)
    spellcheckDelayed(bp.Buf, bp)
end

-- function onCopy(bp)
-- end

-- function onCopyLine(bp)
-- end

function onCut(bp)
    spellcheckDelayed(bp.Buf, bp)
end

function onCutLine(bp)
    spellcheckDelayed(bp.Buf, bp)
end

function onDuplicateLine(bp)
    spellcheckDelayed(bp.Buf, bp)
end

function onDeleteLine(bp)
    spellcheckDelayed(bp.Buf, bp)
end

function onIndentSelection(bp)
    spellcheckDelayed(bp.Buf, bp)
end

function onOutdentSelection(bp)
    spellcheckDelayed(bp.Buf, bp)
end

function onOutdentLine(bp)
    spellcheckDelayed(bp.Buf, bp)
end

function onIndentLine(bp)
    spellcheckDelayed(bp.Buf, bp)
end

function onPaste(bp)
    spellcheckDelayed(bp.Buf, bp)
end

-- function onSelectAll(bp)
-- end

-- function onOpenFile(bp)
-- end

function onStart(bp)
    updateCursorTracking(bp.Buf, bp)
end

function onEnd(bp)
    updateCursorTracking(bp.Buf, bp)
end

function onPageUp(bp)
    -- Page up/down changes visible area, trigger spell check
    currentBufPane = bp
    lastCursorLine = bp.Cursor.Y
    spellcheckDelayed(bp.Buf, bp)
end

function onPageDown(bp)
    -- Page up/down changes visible area, trigger spell check
    currentBufPane = bp
    lastCursorLine = bp.Cursor.Y
    spellcheckDelayed(bp.Buf, bp)
end

-- function onSelectPageUp(bp)
-- end

-- function onSelectPageDown(bp)
-- end

function onHalfPageUp(bp)
    -- Half page scrolling changes visible area, trigger spell check
    currentBufPane = bp
    lastCursorLine = bp.Cursor.Y
    spellcheckDelayed(bp.Buf, bp)
end

function onHalfPageDown(bp)
    -- Half page scrolling changes visible area, trigger spell check
    currentBufPane = bp
    lastCursorLine = bp.Cursor.Y
    spellcheckDelayed(bp.Buf, bp)
end

-- function onStartOfLine(bp)
-- end

-- function onEndOfLine(bp)
-- end

-- function onStartOfText(bp)
-- end

-- function onStartOfTextToggle(bp)
-- end

-- function onParagraphPrevious(bp)
-- end

-- function onParagraphNext(bp)
-- end

-- function onToggleHelp(bp)
-- end

-- function onToggleDiffGutter(bp)
-- end

-- function onToggleRuler(bp)
-- end

function onJumpLine(bp)
    updateCursorTracking(bp.Buf, bp)
end

function onGoto(bp)
    updateCursorTracking(bp.Buf, bp)
end

-- function onClearStatus(bp)
-- end

-- function onShellMode(bp)
-- end

-- function onCommandMode(bp)
-- end

-- function onQuit(bp)
-- end

-- function onQuitAll(bp)
-- end

-- function onAddTab(bp)
-- end

-- function onPreviousTab(bp)
-- end

-- function onNextTab(bp)
-- end

-- function onNextSplit(bp)
-- end

-- function onUnsplit(bp)
-- end

-- function onVSplit(bp)
-- end

-- function onHSplit(bp)
-- end

-- function onPreviousSplit(bp)
-- end

-- function onToggleMacro(bp)
-- end

function onPlayMacro(bp)
    spellcheckDelayed(bp.Buf, bp)
end

-- function onSuspend(bp) -- Unix only
-- end

function onScrollUp(bp)
    -- Scrolling changes visible area, always trigger spell check
    currentBufPane = bp
    spellcheckDelayed(bp.Buf, bp)
end

function onScrollDown(bp)
    -- Scrolling changes visible area, always trigger spell check
    currentBufPane = bp
    spellcheckDelayed(bp.Buf, bp)
end

-- function onSpawnMultiCursor(bp)
-- end

-- function onSpawnMultiCursorUp(bp)
-- end

-- function onSpawnMultiCursorDown(bp)
-- end

-- function onSpawnMultiCursorSelect(bp)
-- end

-- function onRemoveMultiCursor(bp)
-- end

-- function onRemoveAllMultiCursors(bp)
-- end

-- function onSkipMultiCursor(bp)
-- end

-- function onNone(bp)
-- end

-- function onJumpToMatchingBrace(bp)
-- end

function onAutocomplete(bp)
    spellcheckDelayed(bp.Buf, bp)
end

-- Debug function to detect any event
--function onAnyEvent()
    -- Log events to help debug goto line issue
    -- This will be removed once goto line detection is working
    -- micro.InfoBar():Message("Event detected")
--end
