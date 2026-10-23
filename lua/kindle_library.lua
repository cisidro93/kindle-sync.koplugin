local BD = require("ui/bidi")
local InfoMessage = require("ui/widget/infomessage")
local Trapper = require("ui/trapper")
local UIManager = require("ui/uimanager")
local filemanagerutil = require("apps/filemanager/filemanagerutil")
local logger = require("logger")
local _ = require("gettext")
local T = require("ffi/util").template

local KindleLibrary = {}
KindleLibrary.__index = KindleLibrary

function KindleLibrary:new(virtual_library, cache_manager)
    return setmetatable({
        virtual_library = virtual_library,
        cache_manager = cache_manager,
        ui = nil,
        browsing = false,
        return_to_library_request = nil,
    }, self)
end

function KindleLibrary:setUI(ui)
    if self.ui ~= ui then
        self:leave()
        self.ui = ui
    end
end

function KindleLibrary:requestReturnToLibrary(origin_path)
    self.return_to_library_request = {
        origin_path = origin_path,
    }
end

function KindleLibrary:takeReturnToLibraryRequest()
    local request = self.return_to_library_request
    self.return_to_library_request = nil
    return request
end

local function showInfo(text, timeout)
    UIManager:show(InfoMessage:new({ text = text, timeout = timeout or 4 }))
end

function KindleLibrary:isBrowsing(file_chooser)
    return self.browsing
        and file_chooser
        and file_chooser.name == "filemanager"
        and file_chooser.ui == self.ui
        and file_chooser.path == self.origin_path
end

-- Stop supplying catalog rows without repainting a FileManager being torn down.
function KindleLibrary:leave()
    self.browsing = false
    self.origin_path = nil
    self.book_count = nil
end

function KindleLibrary:close()
    local was_browsing = self.browsing
    self:leave()
    if was_browsing and self.ui and self.ui.file_chooser then
        self.ui.file_chooser:refreshPath()
        self.ui:updateTitleBarPath()
    end
end

function KindleLibrary:updateTitle(file_chooser)
    if self:isBrowsing(file_chooser) then
        self.ui.title_bar:setSubTitle(T(_("Kindle Library (%1)"), self.book_count or 0))
    end
end

function KindleLibrary:buildEntries(file_chooser, force)
    local files, err, unavailable = self.virtual_library:getBookEntries(file_chooser, force)
    if not files then
        showInfo(_("Failed to build Kindle library:\n") .. (err or _("unknown error")))
        return nil
    end
    -- Keep native collation and item construction, but do not claim that this
    -- catalog is the filesystem contents of FileChooser.path.
    local entries = file_chooser:genItemTable({}, files)
    for _, item in ipairs(unavailable) do
        entries[#entries + 1] = item
    end
    self.book_count = #entries
    table.insert(entries, 1, {
        text = _("Back to file browser"),
        path = self.origin_path,
        is_go_up = true,
        is_kindle_library_return = true,
    })
    return entries
end

function KindleLibrary:show(ui, force)
    self:setUI(ui or self.ui)
    local file_chooser = self.ui and self.ui.file_chooser
    if not file_chooser then
        return false
    end

    local books, err = self.virtual_library:refresh(force ~= false)
    if not books then
        showInfo(_("Failed to build Kindle library:\n") .. (err or _("unknown error")))
        return false
    end
    if #books == 0 then
        showInfo(_("No Kindle books were found in the Kindle content catalog."))
        return false
    end

    self.origin_path = file_chooser.path
    self.browsing = true
    file_chooser:refreshPath()
    return self.browsing
end

function KindleLibrary:openItem(item)
    local book = item and self.virtual_library:getBook(item.kindle_book_id)
    if not book then
        showInfo(_("Book entry is no longer available."))
        return true
    end
    if book.open_mode == "blocked" then
        showInfo(self.virtual_library:getBlockedReasonText(book))
        return true
    end

    if not book.source_path or item.kindle_unavailable then
        showInfo(self.virtual_library:getBlockedReasonText({ block_reason = "missing_source" }))
        return true
    end

    -- Request the real Kindle source path. open_file_ext resolves convertible
    -- books to their real cached EPUB only after KOReader's optional open
    -- confirmation has been accepted.
    logger.info("KindlePlugin: requesting native open for:", book.source_path)
    filemanagerutil.openFile(self.ui, book.source_path, function()
        -- Confirmation and preparation have succeeded. A cancelled or failed
        -- open must leave the catalog visible and must not schedule a return.
        if self.browsing then
            self:requestReturnToLibrary(self.origin_path)
            self:leave()
        end
    end)
    return true
end

function KindleLibrary:showBookInfo(book)
    if not book then
        return true
    end
    local details = BD.auto(book.display_name or book.title or book.id)
    details = details .. "\n\n" .. (book.source_path and BD.filepath(book.source_path) or _("Cloud-only Kindle entry"))
    if book.cde_key and book.cde_key ~= "" then
        details = details .. "\n\n" .. T(_("Kindle Key: %1"), book.cde_key)
    end
    if book.open_mode == "convert" then
        if self.virtual_library:isBookPrepared(book) then
            details = details .. "\n\n" .. _("Status: Prepared for KOReader (cached)")
        else
            details = details .. "\n\n" .. _("Status: Not prepared for KOReader")
        end
    elseif book.open_mode == "direct" then
        details = details .. "\n\n" .. _("Status: Direct open (no conversion needed)")
    elseif book.open_mode == "blocked" then
        details = details .. "\n\n" .. self.virtual_library:getBlockedReasonText(book)
    end
    showInfo(details)
    return true
end

function KindleLibrary:prepareBook(book)
    if not book then
        return false, "missing book"
    end
    if book.open_mode ~= "convert" then
        if book.open_mode == "blocked" then
            showInfo(self.virtual_library:getBlockedReasonText(book))
        else
            showInfo(_("This book does not require conversion."))
        end
        return false
    end
    if self.virtual_library:isBookPrepared(book) then
        showInfo(_("This book is already prepared for reading."))
        return true
    end

    local title = BD.auto(book.display_name or book.title or book.id)
    local ok = false
    local err_msg = nil
    Trapper:wrap(function()
        Trapper:info(T(_("Preparing book for KOReader:\n%1"), title))
        local cached_path, err = self.virtual_library:resolveBookPath(book)
        if cached_path then
            ok = true
        else
            err_msg = err or _("unknown error")
        end
    end)

    if ok then
        showInfo(T(_("Successfully prepared:\n%1"), title), 3)
        if self.ui and self.ui.file_chooser then
            self.ui.file_chooser:refreshPath()
        end
        return true
    else
        showInfo(T(_("Failed to prepare book:\n%1\n\n%2"), title, self.virtual_library:getBlockedReasonText({ block_reason = err_msg })))
        return false, err_msg
    end
end

function KindleLibrary:prepareAllBooks(books_subset)
    local books = books_subset or self.virtual_library:getUnpreparedBooks(false)
    if not books then
        showInfo(_("Failed to query Kindle library for unprepared books."))
        return 0, 0
    end
    if #books == 0 then
        showInfo(_("All convertible Kindle books are already prepared."), 3)
        return 0, 0
    end

    local total = #books
    local prepared_count = 0
    local failed_count = 0
    local aborted = false

    Trapper:wrap(function()
        Trapper:setPausedText(_("Do you want to abort book preparation?"), _("Abort"), _("Continue"))
        for i, book in ipairs(books) do
            local title = BD.auto(book.display_name or book.title or book.id)
            local go_on = Trapper:info(T(_("Preparing (%1 / %2):\n%3"), i, total, title))
            if not go_on then
                aborted = true
                logger.info("KindlePlugin: batch preparation aborted at book", i, "of", total)
                break
            end

            local cached_path, err = self.virtual_library:resolveBookPath(book)
            if cached_path then
                prepared_count = prepared_count + 1
            else
                failed_count = failed_count + 1
                logger.warn("KindlePlugin: batch preparation failed for", book.id, err)
            end
        end
    end)

    if self.ui and self.ui.file_chooser then
        self.ui.file_chooser:refreshPath()
    end

    local summary
    if aborted then
        summary = T(_("Preparation aborted. Prepared: %1, Failed: %2 of %3 books."), prepared_count, failed_count, total)
    elseif failed_count > 0 then
        summary = T(_("Batch preparation completed with errors. Prepared: %1, Failed: %2 of %3 books."), prepared_count, failed_count, total)
    else
        summary = T(_("Successfully prepared %1 books for KOReader."), prepared_count)
    end
    showInfo(summary, 4)
    return prepared_count, failed_count
end

function KindleLibrary:fileDialogButtons(file, is_file)
    local book = is_file and self.virtual_library:getBook(file)
    if not book then
        return nil
    end
    local file_chooser = self.ui.file_chooser
    local function closeDialog()
        UIManager:close(file_chooser.file_dialog)
    end
    return {
        {
            text = _("Kindle information"),
            callback = function()
                closeDialog()
                self:showBookInfo(book)
            end,
        },
        {
            text = _("Clear Kindle cache"),
            enabled = book.open_mode ~= "direct",
            callback = function()
                closeDialog()
                local ok, err = self.cache_manager:clearBookCache(book)
                if not ok then
                    showInfo(_("Failed to clear cache:\n") .. (err or _("unknown error")))
                    return
                end
                file_chooser:refreshPath()
            end,
        },
        {
            text = _("Refresh Kindle library"),
            callback = function()
                closeDialog()
                self:show(self.ui, true)
            end,
        },
        {
            text = _("Prepare for KOReader"),
            enabled = book.open_mode == "convert" and not self.virtual_library:isBookPrepared(book),
            callback = function()
                closeDialog()
                self:prepareBook(book)
            end,
        },
        {
            text = _("Prepare all unprepared books"),
            callback = function()
                closeDialog()
                self:prepareAllBooks()
            end,
        },
    }
end

return KindleLibrary
