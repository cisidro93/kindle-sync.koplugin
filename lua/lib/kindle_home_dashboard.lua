local Blitbuffer = require("ffi/blitbuffer")
local BottomContainer = require("ui/widget/container/bottomcontainer")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local ImageWidget = require("ui/widget/imagewidget")
local InfoMessage = require("ui/widget/infomessage")
local InputContainer = require("ui/widget/container/inputcontainer")
local LeftContainer = require("ui/widget/container/leftcontainer")
local LineWidget = require("ui/widget/linewidget")
local Menu = require("ui/widget/menu")
local OverlapGroup = require("ui/widget/overlapgroup")
local ProgressWidget = require("ui/widget/progresswidget")
local RightContainer = require("ui/widget/container/rightcontainer")
local Size = require("ui/size")
local TextBoxWidget = require("ui/widget/textboxwidget")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local logger = require("logger")
local _ = require("gettext")
local Screen = Device.screen
local T = require("ffi/util").template

local KindleHomeDashboard = {}
KindleHomeDashboard.__index = KindleHomeDashboard

function KindleHomeDashboard:new(
    plugin,
    virtual_library,
    kindle_library,
    goal_tracker,
    collections_sync,
    highlights_viewer,
    manga_mode,
    zlibrary_guard
)
    local instance = {
        plugin = plugin,
        virtual_library = virtual_library,
        kindle_library = kindle_library,
        goal_tracker = goal_tracker,
        collections_sync = collections_sync,
        highlights_viewer = highlights_viewer,
        manga_mode = manga_mode,
        zlibrary_guard = zlibrary_guard,
        active_menu = nil,
        current_tab = "home",
        shelf_page = 1,
        library_page = 1,
        library_filter = "all",
        manga_page = 1,
    }
    setmetatable(instance, self)
    return instance
end

local function showInfo(text, timeout)
    UIManager:show(InfoMessage:new({ text = text, timeout = timeout or 3 }))
end

local function safeCallback(label, fn)
    return function()
        local ok, err = pcall(fn)
        if not ok then
            logger.warn("KindleHomeDashboard:", label, "failed:", err)
            showInfo(T(_("Action failed:\n%1"), tostring(err)), 4)
        end
    end
end

local function formatAuthors(authors)
    if type(authors) == "table" then
        local parts = {}
        for __, a in ipairs(authors) do
            if type(a) == "string" and a ~= "" then
                table.insert(parts, a)
            end
        end
        return table.concat(parts, ", ")
    elseif type(authors) == "string" then
        return authors
    end
    return ""
end

local function normalizePercent(pct)
    local n = tonumber(pct)
    if not n or n <= 0 then
        return 0
    end
    if n > 1 then
        return math.min(1, n / 100)
    end
    return math.min(1, n)
end

local function makeTappable(child_widget, w, h, on_tap, on_hold)
    local tappable = InputContainer:new({
        dimen = Geom:new({ w = w, h = h }),
        [1] = child_widget,
    })
    tappable.ges_events = {}
    if on_tap then
        tappable.ges_events.TapTile = {
            GestureRange:new({
                ges = "tap",
                range = function()
                    return tappable.dimen
                end,
            }),
        }
        function tappable:onTapTile()
            on_tap()
            return true
        end
    end
    if on_hold then
        tappable.ges_events.HoldTile = {
            GestureRange:new({
                ges = "hold",
                range = function()
                    return tappable.dimen
                end,
            }),
        }
        function tappable:onHoldTile()
            on_hold()
            return true
        end
    end
    return tappable
end

local function makePillButton(text, w, h, is_primary, on_tap, font_size)
    local fsize = font_size or 14
    local bg = is_primary and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_GRAY_E
    local fg = is_primary and Blitbuffer.COLOR_WHITE or Blitbuffer.COLOR_BLACK
    local border_clr = is_primary and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_GRAY_7
    local frame = FrameContainer:new({
        width = w,
        height = h,
        margin = 0,
        padding = 0,
        bordersize = Size.border.thin,
        color = border_clr,
        background = bg,
        radius = Screen:scaleBySize(8),
        CenterContainer:new({
            dimen = Geom:new({ w = w - 2 * Size.border.thin, h = h - 2 * Size.border.thin }),
            TextWidget:new({
                text = text,
                face = Font:getFace("cfont", fsize),
                bold = true,
                fgcolor = fg,
                max_width = w - Screen:scaleBySize(12),
            }),
        }),
    })
    return makeTappable(frame, w, h, on_tap)
end

--- Get summary text for Whispersync status.
--- @return string
function KindleHomeDashboard:getWhispersyncStatusText()
    local last_time = self.plugin and self.plugin.last_whispersync_time
    if last_time then
        local elapsed = os.time() - last_time
        local mins = math.floor(elapsed / 60)
        if mins < 1 then
            return _("Synced just now")
        elseif mins == 1 then
            return _("Synced 1 min ago")
        else
            return T(_("Synced %1 mins ago"), mins)
        end
    end
    return _("Connected • Tap to sync")
end

--- Fetch all books from VirtualLibrary safely.
--- @return table
function KindleHomeDashboard:getAllBooks()
    if not self.virtual_library then
        return {}
    end
    if type(self.virtual_library.getOrderedBooks) == "function" then
        local ok, res = pcall(self.virtual_library.getOrderedBooks, self.virtual_library, false)
        if ok and type(res) == "table" then
            return res
        end
    end
    if type(self.virtual_library.buildMappings) == "function" then
        local ok, res = pcall(self.virtual_library.buildMappings, self.virtual_library, false)
        if ok and type(res) == "table" then
            return res
        end
    end
    return {}
end

--- Get last opened book info, falling back to the most recently accessed Kindle book.
--- @return table|nil
function KindleHomeDashboard:getLastOpenedBook()
    local lastfile = G_reader_settings:readSetting("lastfile")
    if lastfile and lastfile ~= "" then
        if self.virtual_library then
            local ok, book = pcall(self.virtual_library.getBook, self.virtual_library, lastfile)
            if ok and book then
                return book
            end
        end
        local title = lastfile:match("([^/]+)%.%w+$") or lastfile
        return {
            title = title,
            source_path = lastfile,
        }
    end

    local all_books = self:getAllBooks()
    local best_book = nil
    local best_access = -1
    for __, book in ipairs(all_books) do
        local access = tonumber(book.last_access) or 0
        local pct = normalizePercent(book.percent_finished)
        if access > best_access or (best_book == nil and pct > 0) then
            best_access = access
            best_book = book
        end
    end
    return best_book or all_books[1]
end

--- Open a book safely while preserving KindleOS return state.
--- @param book table
function KindleHomeDashboard:openBook(book)
    if not book then
        return
    end
    local open_path = book.source_path or book.cached_path
    if self.virtual_library and self.virtual_library.cache_manager and type(self.virtual_library.isBookPrepared) == "function" then
        local ok_p, is_prep = pcall(self.virtual_library.isBookPrepared, self.virtual_library, book)
        if ok_p and is_prep and type(self.virtual_library.cache_manager.getCachePaths) == "function" then
            local cached = self.virtual_library.cache_manager:getCachePaths(book)
            if cached then
                open_path = cached
            end
        end
    end
    if not open_path or open_path == "" then
        if self.kindle_library and type(self.kindle_library.showBookInfo) == "function" then
            self.kindle_library:showBookInfo(book)
        else
            showInfo(_("This book has no local file on the device."))
        end
        return
    end

    local ui = (self.kindle_library and self.kindle_library.ui) or (self.plugin and self.plugin.ui)
    local filemanagerutil = require("apps/filemanager/filemanagerutil")
    self.return_after_reader = true
    if ui then
        filemanagerutil.openFile(ui, open_path, function()
            if self.active_menu then
                UIManager:close(self.active_menu)
                self.active_menu = nil
            end
        end)
    else
        if self.active_menu then
            UIManager:close(self.active_menu)
            self.active_menu = nil
        end
        filemanagerutil.openFile(open_path)
    end
end

--- Build a cover widget (ImageWidget from CoverCacheImporter or stylized FakeCover).
function KindleHomeDashboard:buildCoverWidget(book, cw, ch)
    local border_sz = Size.border.thin
    local inner_w = math.max(10, cw - 2 * border_sz)
    local inner_h = math.max(10, ch - 2 * border_sz)

    local importer = self.kindle_library and self.kindle_library.cover_importer
    if importer and book and type(importer.getBookCoverBb) == "function" then
        local ok, cover_bb = pcall(importer.getBookCoverBb, importer, book, inner_w, inner_h)
        if ok and cover_bb then
            local img = ImageWidget:new({
                image = cover_bb,
                image_disposable = true,
                width = inner_w,
                height = inner_h,
                scale_factor = 1,
            })
            return FrameContainer:new({
                width = cw,
                height = ch,
                margin = 0,
                padding = 0,
                bordersize = border_sz,
                color = Blitbuffer.COLOR_GRAY_5,
                background = Blitbuffer.COLOR_WHITE,
                CenterContainer:new({
                    dimen = Geom:new({ w = inner_w, h = inner_h }),
                    img,
                }),
            })
        end
    end

    local title_str = book and (book.title or book.display_name) or _("Untitled")
    local author_str = book and formatAuthors(book.authors or book.author) or ""
    local pad = Screen:scaleBySize(6)
    local text_w = math.max(10, inner_w - 2 * pad)
    return FrameContainer:new({
        width = cw,
        height = ch,
        margin = 0,
        padding = 0,
        bordersize = border_sz,
        color = Blitbuffer.COLOR_GRAY_5,
        background = Blitbuffer.COLOR_GRAY_E,
        CenterContainer:new({
            dimen = Geom:new({ w = inner_w, h = inner_h }),
            VerticalGroup:new({
                align = "center",
                TextBoxWidget:new({
                    text = tostring(title_str),
                    face = Font:getFace("cfont", 13),
                    bold = true,
                    width = text_w,
                    height = math.floor(inner_h * 0.55),
                    alignment = "center",
                }),
                VerticalSpan:new({ width = Screen:scaleBySize(4) }),
                TextWidget:new({
                    text = tostring(author_str),
                    face = Font:getFace("cfont", 11),
                    fgcolor = Blitbuffer.COLOR_DARK_GRAY,
                    max_width = text_w,
                }),
            }),
        }),
    })
end

--- Build a single visual book tile (cover + progress bar + title + % Read).
function KindleHomeDashboard:buildBookTile(book, cell_w, cell_h, show_author)
    local pad_v = Screen:scaleBySize(4)
    local bar_h = Screen:scaleBySize(6)
    local text_h = show_author and Screen:scaleBySize(38) or Screen:scaleBySize(32)
    local ch = math.max(40, cell_h - bar_h - text_h - 3 * pad_v)
    local cw = math.min(cell_w - Screen:scaleBySize(6), math.floor(ch * 0.68))

    local cover_widget = self:buildCoverWidget(book, cw, ch)
    local pct = normalizePercent(book and book.percent_finished)
    local pct_int = math.floor(pct * 100 + 0.5)
    local status_str = pct_int > 0 and string.format(_("%d%% Read"), pct_int) or _("New")
    if show_author then
        local auth = formatAuthors(book and (book.authors or book.author))
        if auth ~= "" then
            status_str = pct_int > 0 and (string.format("%d%% • ", pct_int) .. auth) or auth
        end
    end

    local pbar = ProgressWidget:new({
        width = cw,
        height = bar_h,
        percentage = pct,
        margin_v = 0,
        margin_h = 0,
    })

    local col = VerticalGroup:new({
        align = "center",
        cover_widget,
        VerticalSpan:new({ width = pad_v }),
        pbar,
        VerticalSpan:new({ width = math.floor(pad_v / 2) }),
        TextWidget:new({
            text = tostring(book and (book.title or book.display_name) or _("Untitled")),
            face = Font:getFace("cfont", 13),
            bold = true,
            max_width = cell_w - Screen:scaleBySize(4),
        }),
        TextWidget:new({
            text = status_str,
            face = Font:getFace("cfont", 11),
            fgcolor = Blitbuffer.COLOR_DARK_GRAY,
            max_width = cell_w - Screen:scaleBySize(4),
        }),
    })

    local container = CenterContainer:new({
        dimen = Geom:new({ w = cell_w, h = cell_h }),
        col,
    })

    return makeTappable(
        container,
        cell_w,
        cell_h,
        safeCallback("Open Tile Book", function()
            self:openBook(book)
        end),
        safeCallback("Hold Tile Book", function()
            if self.kindle_library and type(self.kindle_library.showBookInfo) == "function" then
                self.kindle_library:showBookInfo(book)
            end
        end)
    )
end

--- Build the Top Status & Action Bar.
function KindleHomeDashboard:buildTopBar(sw, header_h, side_pad)
    local tab_titles = {
        home = _("Home"),
        library = _("Library"),
        manga = _("Manga & Comics"),
        zlib = _("Z-Lib Guard"),
        notes = _("Notes & Shelves"),
    }
    local sub_str = tab_titles[self.current_tab] or _("Home")
    local inner_w = sw - 2 * side_pad
    local btn_h = math.max(24, math.floor(header_h * 0.62))
    local sync_w = Screen:scaleBySize(86)
    local search_w = Screen:scaleBySize(86)
    local gap = Screen:scaleBySize(8)

    local left_title = HorizontalGroup:new({
        align = "center",
        TextWidget:new({
            text = "KindleOS",
            face = Font:getFace("tfont", 21),
            bold = true,
        }),
        HorizontalSpan:new({ width = Screen:scaleBySize(8) }),
        TextWidget:new({
            text = "•  " .. sub_str,
            face = Font:getFace("cfont", 15),
            fgcolor = Blitbuffer.COLOR_DARK_GRAY,
        }),
    })

    local sync_btn = makePillButton(
        _("☁ Sync"),
        sync_w,
        btn_h,
        false,
        safeCallback("Top Sync", function()
            if self.plugin and type(self.plugin.triggerKindleCloudSync) == "function" then
                self.plugin:triggerKindleCloudSync()
                self.plugin.last_whispersync_time = os.time()
                showInfo(_("Whispersync cloud sync triggered with Amazon."), 2)
                self:refreshScreen()
            end
        end),
        13
    )

    local search_btn = makePillButton(
        _("🔍 Z-Lib"),
        search_w,
        btn_h,
        false,
        safeCallback("Top Search", function()
            local guard = self.zlibrary_guard or (self.plugin and self.plugin.zlibrary_guard)
            if guard then
                guard:showLibraryCheckDialog()
            else
                self:switchTab("zlib")
            end
        end),
        13
    )

    local row_h = header_h - Size.line.medium
    local bar_overlap = OverlapGroup:new({
        dimen = Geom:new({ w = inner_w, h = row_h }),
        LeftContainer:new({
            dimen = Geom:new({ w = inner_w, h = row_h }),
            left_title,
        }),
        RightContainer:new({
            dimen = Geom:new({ w = inner_w, h = row_h }),
            HorizontalGroup:new({
                align = "center",
                sync_btn,
                HorizontalSpan:new({ width = gap }),
                search_btn,
            }),
        }),
    })

    return VerticalGroup:new({
        align = "center",
        CenterContainer:new({
            dimen = Geom:new({ w = sw, h = row_h }),
            bar_overlap,
        }),
        LineWidget:new({
            dimen = Geom:new({ w = sw, h = Size.line.medium }),
            background = Blitbuffer.COLOR_GRAY_9,
        }),
    })
end

--- Build the Bottom Navigation Tab Bar (SimpleUI-style).
function KindleHomeDashboard:buildBottomBar(sw, nav_h)
    local tabs = {
        { id = "home", label = _("⌂ Home") },
        { id = "library", label = _("📚 Library") },
        { id = "manga", label = _("🎨 Manga") },
        { id = "zlib", label = _("🔍 Z-Lib") },
        { id = "notes", label = _("📝 Notes") },
        { id = "files", label = _("📂 Files") },
    }
    local tab_w = math.floor(sw / #tabs)
    local inner_h = nav_h - Size.line.medium
    local indicator_h = Size.line.thick * 2

    local row = HorizontalGroup:new({ align = "center" })
    for __, tab in ipairs(tabs) do
        local is_active = (self.current_tab == tab.id)
        local indicator = LineWidget:new({
            dimen = Geom:new({ w = math.floor(tab_w * 0.64), h = indicator_h }),
            background = is_active and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_WHITE,
        })
        local label_w = TextWidget:new({
            text = tab.label,
            face = Font:getFace("cfont", 14),
            bold = is_active,
            fgcolor = is_active and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_DARK_GRAY,
            max_width = tab_w - Screen:scaleBySize(6),
        })
        local tab_col = VerticalGroup:new({
            align = "center",
            indicator,
            CenterContainer:new({
                dimen = Geom:new({ w = tab_w, h = inner_h - indicator_h }),
                label_w,
            }),
        })
        local tappable_tab = makeTappable(
            tab_col,
            tab_w,
            inner_h,
            safeCallback("Switch Tab " .. tab.id, function()
                if tab.id == "files" then
                    self:openNativeBrowser()
                else
                    self:switchTab(tab.id)
                end
            end)
        )
        table.insert(row, tappable_tab)
    end

    return VerticalGroup:new({
        align = "center",
        LineWidget:new({
            dimen = Geom:new({ w = sw, h = Size.line.medium }),
            background = Blitbuffer.COLOR_GRAY_7,
        }),
        FrameContainer:new({
            width = sw,
            height = inner_h,
            margin = 0,
            padding = 0,
            bordersize = 0,
            background = Blitbuffer.COLOR_WHITE,
            row,
        }),
    })
end

--- Build Tab 1: Sleek Bento Home View.
function KindleHomeDashboard:buildHomeTab(inner_w, body_h, all_books)
    local vgap = math.max(6, math.floor(body_h * 0.018))
    local hero_h = math.floor(body_h * 0.27)
    local bento_h = math.floor(body_h * 0.16)
    local action_h = math.floor(body_h * 0.075)
    local shelf_h = body_h - hero_h - bento_h - action_h - 4 * vgap

    -- 1. Hero Card: Currently Reading
    local hero_book = self:getLastOpenedBook()
    local hero_pad = Screen:scaleBySize(12)
    local cover_h = math.max(50, hero_h - 2 * hero_pad)
    local cover_w = math.floor(cover_h * 0.68)
    local meta_w = math.max(80, inner_w - cover_w - 3 * hero_pad - 2 * Size.border.thin)

    local hero_cover = self:buildCoverWidget(hero_book, cover_w, cover_h)
    local hero_title = hero_book and (hero_book.title or hero_book.display_name) or _("Welcome to KindleOS")
    local hero_author = hero_book and formatAuthors(hero_book.authors or hero_book.author) or _("Select a book below to begin reading")
    local hero_pct = normalizePercent(hero_book and hero_book.percent_finished)
    local hero_pct_int = math.floor(hero_pct * 100 + 0.5)

    local resume_btn_w = math.min(meta_w, Screen:scaleBySize(190))
    local resume_btn_h = math.max(26, math.floor(cover_h * 0.22))
    local resume_btn = makePillButton(
        _("▶ Continue Reading"),
        resume_btn_w,
        resume_btn_h,
        true,
        safeCallback("Hero Resume", function()
            if hero_book then
                self:openBook(hero_book)
            end
        end),
        14
    )

    local meta_col = VerticalGroup:new({
        align = "left",
        TextWidget:new({
            text = _("CURRENTLY READING"),
            face = Font:getFace("cfont", 12),
            bold = true,
            fgcolor = Blitbuffer.COLOR_DARK_GRAY,
        }),
        VerticalSpan:new({ width = Screen:scaleBySize(3) }),
        TextWidget:new({
            text = tostring(hero_title),
            face = Font:getFace("tfont", 19),
            bold = true,
            max_width = meta_w,
        }),
        TextWidget:new({
            text = hero_author ~= "" and hero_author or _("Kindle Edition"),
            face = Font:getFace("cfont", 14),
            fgcolor = Blitbuffer.COLOR_DARK_GRAY,
            max_width = meta_w,
        }),
        VerticalSpan:new({ width = Screen:scaleBySize(6) }),
        HorizontalGroup:new({
            align = "center",
            ProgressWidget:new({
                width = math.floor(meta_w * 0.72),
                height = Screen:scaleBySize(8),
                percentage = hero_pct,
                margin_v = 0,
                margin_h = 0,
            }),
            HorizontalSpan:new({ width = Screen:scaleBySize(8) }),
            TextWidget:new({
                text = string.format("%d%%", hero_pct_int),
                face = Font:getFace("cfont", 13),
                bold = true,
            }),
        }),
        VerticalSpan:new({ width = Screen:scaleBySize(8) }),
        resume_btn,
    })

    local hero_frame = FrameContainer:new({
        width = inner_w,
        height = hero_h,
        margin = 0,
        padding = hero_pad,
        bordersize = Size.border.thin,
        color = Blitbuffer.COLOR_GRAY_7,
        background = Blitbuffer.COLOR_WHITE,
        radius = Screen:scaleBySize(12),
        HorizontalGroup:new({
            align = "center",
            hero_cover,
            HorizontalSpan:new({ width = hero_pad }),
            CenterContainer:new({
                dimen = Geom:new({ w = meta_w, h = cover_h }),
                meta_col,
            }),
        }),
    })
    local hero_widget = makeTappable(
        hero_frame,
        inner_w,
        hero_h,
        safeCallback("Tap Hero Card", function()
            if hero_book then
                self:openBook(hero_book)
            end
        end)
    )

    -- 2. Bento Row: Daily Reading Goal Card + Library & Whispersync Card
    local goal_data = {}
    if self.goal_tracker and type(self.goal_tracker.getData) == "function" then
        local ok, res = pcall(self.goal_tracker.getData, self.goal_tracker)
        if ok and type(res) == "table" then
            goal_data = res
        end
    end
    local streak = tonumber(goal_data.streak_days) or 0
    local today_mins = tonumber(goal_data.today_minutes) or 0
    local target_mins = math.max(1, tonumber(goal_data.target_minutes) or 30)
    local goal_pct = math.min(1, today_mins / target_mins)

    local card_gap = Screen:scaleBySize(12)
    local card_w = math.floor((inner_w - card_gap) / 2)
    local card_pad = Screen:scaleBySize(10)
    local card_inner_w = card_w - 2 * card_pad - 2 * Size.border.thin

    local goal_card_frame = FrameContainer:new({
        width = card_w,
        height = bento_h,
        margin = 0,
        padding = card_pad,
        bordersize = Size.border.thin,
        color = Blitbuffer.COLOR_GRAY_7,
        background = Blitbuffer.COLOR_GRAY_E,
        radius = Screen:scaleBySize(10),
        VerticalGroup:new({
            align = "left",
            TextWidget:new({
                text = _("🔥 READING GOAL & STREAK"),
                face = Font:getFace("cfont", 12),
                bold = true,
                fgcolor = Blitbuffer.COLOR_DARK_GRAY,
                max_width = card_inner_w,
            }),
            VerticalSpan:new({ width = Screen:scaleBySize(4) }),
            TextWidget:new({
                text = T(_("%1 / %2 mins today"), today_mins, target_mins),
                face = Font:getFace("tfont", 17),
                bold = true,
                max_width = card_inner_w,
            }),
            VerticalSpan:new({ width = Screen:scaleBySize(4) }),
            ProgressWidget:new({
                width = card_inner_w,
                height = Screen:scaleBySize(7),
                percentage = goal_pct,
                margin_v = 0,
                margin_h = 0,
            }),
            VerticalSpan:new({ width = Screen:scaleBySize(4) }),
            TextWidget:new({
                text = streak > 0 and T(_("%1-day active streak • Tap for stats"), streak) or _("Tap to configure daily goal"),
                face = Font:getFace("cfont", 12),
                fgcolor = Blitbuffer.COLOR_DARK_GRAY,
                max_width = card_inner_w,
            }),
        }),
    })
    local goal_card = makeTappable(
        goal_card_frame,
        card_w,
        bento_h,
        safeCallback("Open Goal Tracker", function()
            if self.goal_tracker then
                self.goal_tracker:showDashboard()
            end
        end)
    )

    local ws_status = self:getWhispersyncStatusText()
    local lib_card_frame = FrameContainer:new({
        width = card_w,
        height = bento_h,
        margin = 0,
        padding = card_pad,
        bordersize = Size.border.thin,
        color = Blitbuffer.COLOR_GRAY_7,
        background = Blitbuffer.COLOR_GRAY_E,
        radius = Screen:scaleBySize(10),
        VerticalGroup:new({
            align = "left",
            TextWidget:new({
                text = _("📚 KINDLE LIBRARY & CLOUD"),
                face = Font:getFace("cfont", 12),
                bold = true,
                fgcolor = Blitbuffer.COLOR_DARK_GRAY,
                max_width = card_inner_w,
            }),
            VerticalSpan:new({ width = Screen:scaleBySize(4) }),
            TextWidget:new({
                text = T(_("%1 Books Indexed"), #all_books),
                face = Font:getFace("tfont", 17),
                bold = true,
                max_width = card_inner_w,
            }),
            VerticalSpan:new({ width = Screen:scaleBySize(4) }),
            TextWidget:new({
                text = "☁ " .. ws_status,
                face = Font:getFace("cfont", 12),
                fgcolor = Blitbuffer.COLOR_DARK_GRAY,
                max_width = card_inner_w,
            }),
            VerticalSpan:new({ width = Screen:scaleBySize(2) }),
            TextWidget:new({
                text = _("Tap to browse full cover grid ›"),
                face = Font:getFace("cfont", 12),
                bold = true,
                max_width = card_inner_w,
            }),
        }),
    })
    local lib_card = makeTappable(
        lib_card_frame,
        card_w,
        bento_h,
        safeCallback("Switch to Library Tab", function()
            self:switchTab("library")
        end)
    )

    local bento_row = HorizontalGroup:new({
        align = "center",
        goal_card,
        HorizontalSpan:new({ width = card_gap }),
        lib_card,
    })

    -- 3. Visual 4-Book Cover Shelf ("ON YOUR KINDLE")
    local shelf_cols = 4
    local total_shelf_pages = math.max(1, math.ceil(#all_books / shelf_cols))
    if self.shelf_page > total_shelf_pages then
        self.shelf_page = 1
    end
    local shelf_hdr_h = Screen:scaleBySize(28)
    local nav_btn_w = Screen:scaleBySize(38)
    local see_all_w = Screen:scaleBySize(92)

    local shelf_hdr = OverlapGroup:new({
        dimen = Geom:new({ w = inner_w, h = shelf_hdr_h }),
        LeftContainer:new({
            dimen = Geom:new({ w = inner_w, h = shelf_hdr_h }),
            TextWidget:new({
                text = _("ON YOUR KINDLE"),
                face = Font:getFace("cfont", 14),
                bold = true,
            }),
        }),
        RightContainer:new({
            dimen = Geom:new({ w = inner_w, h = shelf_hdr_h }),
            HorizontalGroup:new({
                align = "center",
                makePillButton(
                    "‹",
                    nav_btn_w,
                    shelf_hdr_h - 2,
                    false,
                    safeCallback("Shelf Prev", function()
                        self.shelf_page = self.shelf_page > 1 and (self.shelf_page - 1) or total_shelf_pages
                        self:refreshScreen()
                    end),
                    14
                ),
                HorizontalSpan:new({ width = Screen:scaleBySize(6) }),
                TextWidget:new({
                    text = string.format("%d/%d", self.shelf_page, total_shelf_pages),
                    face = Font:getFace("cfont", 13),
                    fgcolor = Blitbuffer.COLOR_DARK_GRAY,
                }),
                HorizontalSpan:new({ width = Screen:scaleBySize(6) }),
                makePillButton(
                    "›",
                    nav_btn_w,
                    shelf_hdr_h - 2,
                    false,
                    safeCallback("Shelf Next", function()
                        self.shelf_page = self.shelf_page < total_shelf_pages and (self.shelf_page + 1) or 1
                        self:refreshScreen()
                    end),
                    14
                ),
                HorizontalSpan:new({ width = Screen:scaleBySize(8) }),
                makePillButton(
                    _("See All ›"),
                    see_all_w,
                    shelf_hdr_h - 2,
                    false,
                    safeCallback("See All Library", function()
                        self:switchTab("library")
                    end),
                    13
                ),
            }),
        }),
    })

    local row_books_h = math.max(80, shelf_h - shelf_hdr_h - Screen:scaleBySize(6))
    local tile_gap = Screen:scaleBySize(10)
    local tile_w = math.floor((inner_w - (shelf_cols - 1) * tile_gap) / shelf_cols)
    local start_idx = (self.shelf_page - 1) * shelf_cols + 1
    local shelf_row = HorizontalGroup:new({ align = "center" })
    for c = 1, shelf_cols do
        if c > 1 then
            table.insert(shelf_row, HorizontalSpan:new({ width = tile_gap }))
        end
        local b = all_books[start_idx + c - 1]
        if b then
            table.insert(shelf_row, self:buildBookTile(b, tile_w, row_books_h, false))
        else
            table.insert(shelf_row, HorizontalSpan:new({ width = tile_w }))
        end
    end

    local shelf_group = VerticalGroup:new({
        align = "left",
        shelf_hdr,
        VerticalSpan:new({ width = Screen:scaleBySize(6) }),
        shelf_row,
    })

    -- 4. Quick Action Pills Row
    local act_gap = Screen:scaleBySize(10)
    local act_w = math.floor((inner_w - 2 * act_gap) / 3)
    local action_row = HorizontalGroup:new({
        align = "center",
        makePillButton(
            _("🖼 Cache All Covers"),
            act_w,
            action_h,
            false,
            safeCallback("Quick Cache Covers", function()
                if self.kindle_library and type(self.kindle_library.extractAllCovers) == "function" then
                    local count = self.kindle_library:extractAllCovers()
                    showInfo(T(_("Successfully cached %1 covers!"), count), 3)
                    self:refreshScreen()
                end
            end),
            13
        ),
        HorizontalSpan:new({ width = act_gap }),
        makePillButton(
            _("📁 Collections"),
            act_w,
            action_h,
            false,
            safeCallback("Quick Collections", function()
                self:showCollectionsMenu()
            end),
            13
        ),
        HorizontalSpan:new({ width = act_gap }),
        makePillButton(
            _("📝 Highlights"),
            act_w,
            action_h,
            false,
            safeCallback("Quick Highlights", function()
                if self.highlights_viewer then
                    self.highlights_viewer:show()
                end
            end),
            13
        ),
    })

    return VerticalGroup:new({
        align = "center",
        VerticalSpan:new({ width = vgap }),
        hero_widget,
        VerticalSpan:new({ width = vgap }),
        bento_row,
        VerticalSpan:new({ width = vgap }),
        shelf_group,
        VerticalSpan:new({ width = vgap }),
        action_row,
    })
end

--- Build Tab 2 / Tab 3: Full 3x3 Visual Book Cover Grid Inside KindleOS.
function KindleHomeDashboard:buildGridTab(inner_w, body_h, book_list, is_manga_tab)
    local top_ctrl_h = Screen:scaleBySize(36)
    local vgap = Screen:scaleBySize(8)
    local grid_h = body_h - top_ctrl_h - 2 * vgap

    local filtered = {}
    if is_manga_tab then
        filtered = book_list
    else
        for __, b in ipairs(book_list) do
            local pct = normalizePercent(b.percent_finished)
            if self.library_filter == "reading" then
                if pct > 0 and pct < 0.99 then
                    table.insert(filtered, b)
                end
            elseif self.library_filter == "unread" then
                if pct == 0 then
                    table.insert(filtered, b)
                end
            else
                table.insert(filtered, b)
            end
        end
    end

    local cols = 3
    local rows = 3
    local per_page = cols * rows
    local total_pages = math.max(1, math.ceil(#filtered / per_page))
    local page = is_manga_tab and self.manga_page or self.library_page
    if page > total_pages then
        page = 1
        if is_manga_tab then
            self.manga_page = 1
        else
            self.library_page = 1
        end
    end

    local function setPage(new_p)
        if is_manga_tab then
            self.manga_page = new_p
        else
            self.library_page = new_p
        end
        self:refreshScreen()
    end

    local filter_btn_w = Screen:scaleBySize(78)
    local nav_btn_w = Screen:scaleBySize(38)
    local fgap = Screen:scaleBySize(6)

    local left_controls
    if is_manga_tab then
        left_controls = HorizontalGroup:new({
            align = "center",
            TextWidget:new({
                text = T(_("🎨 Comics & Manga (%1) • Auto RTL + Colorsoft Vibrance"), #filtered),
                face = Font:getFace("cfont", 13),
                bold = true,
            }),
        })
    else
        left_controls = HorizontalGroup:new({
            align = "center",
            makePillButton(
                _("All"),
                filter_btn_w,
                top_ctrl_h - 4,
                self.library_filter == "all",
                safeCallback("Filter All", function()
                    self.library_filter = "all"
                    self.library_page = 1
                    self:refreshScreen()
                end),
                12
            ),
            HorizontalSpan:new({ width = fgap }),
            makePillButton(
                _("Reading"),
                filter_btn_w,
                top_ctrl_h - 4,
                self.library_filter == "reading",
                safeCallback("Filter Reading", function()
                    self.library_filter = "reading"
                    self.library_page = 1
                    self:refreshScreen()
                end),
                12
            ),
            HorizontalSpan:new({ width = fgap }),
            makePillButton(
                _("Unread"),
                filter_btn_w,
                top_ctrl_h - 4,
                self.library_filter == "unread",
                safeCallback("Filter Unread", function()
                    self.library_filter = "unread"
                    self.library_page = 1
                    self:refreshScreen()
                end),
                12
            ),
            HorizontalSpan:new({ width = fgap }),
            makePillButton(
                _("List View"),
                Screen:scaleBySize(84),
                top_ctrl_h - 4,
                false,
                safeCallback("Open Text List", function()
                    self:showLibraryCatalog(_("Kindle Library"), filtered)
                end),
                12
            ),
        })
    end

    local right_controls = HorizontalGroup:new({
        align = "center",
        makePillButton(
            "‹",
            nav_btn_w,
            top_ctrl_h - 4,
            false,
            safeCallback("Grid Prev", function()
                setPage(page > 1 and (page - 1) or total_pages)
            end),
            14
        ),
        HorizontalSpan:new({ width = fgap }),
        TextWidget:new({
            text = string.format("%d / %d", page, total_pages),
            face = Font:getFace("cfont", 13),
            bold = true,
        }),
        HorizontalSpan:new({ width = fgap }),
        makePillButton(
            "›",
            nav_btn_w,
            top_ctrl_h - 4,
            false,
            safeCallback("Grid Next", function()
                setPage(page < total_pages and (page + 1) or 1)
            end),
            14
        ),
    })

    local ctrl_bar = OverlapGroup:new({
        dimen = Geom:new({ w = inner_w, h = top_ctrl_h }),
        LeftContainer:new({
            dimen = Geom:new({ w = inner_w, h = top_ctrl_h }),
            left_controls,
        }),
        RightContainer:new({
            dimen = Geom:new({ w = inner_w, h = top_ctrl_h }),
            right_controls,
        }),
    })

    if #filtered == 0 then
        local empty_msg = is_manga_tab
                and _(
                    "No Comics or Manga detected in your library yet.\nBooks with 'Manga', 'Comic', 'Vol.', or .cbz/.cbr are automatically grouped here."
                )
            or _("No books match this filter.")
        local empty_card = FrameContainer:new({
            width = inner_w,
            height = grid_h,
            margin = 0,
            padding = Screen:scaleBySize(20),
            bordersize = Size.border.thin,
            color = Blitbuffer.COLOR_GRAY_7,
            background = Blitbuffer.COLOR_GRAY_E,
            radius = Screen:scaleBySize(12),
            CenterContainer:new({
                dimen = Geom:new({ w = inner_w - Screen:scaleBySize(40), h = grid_h - Screen:scaleBySize(40) }),
                TextBoxWidget:new({
                    text = empty_msg,
                    face = Font:getFace("cfont", 16),
                    width = inner_w - Screen:scaleBySize(60),
                    alignment = "center",
                }),
            }),
        })
        return VerticalGroup:new({
            align = "center",
            VerticalSpan:new({ width = vgap }),
            ctrl_bar,
            VerticalSpan:new({ width = vgap }),
            empty_card,
        })
    end

    local col_gap = Screen:scaleBySize(12)
    local row_gap = Screen:scaleBySize(10)
    local cell_w = math.floor((inner_w - (cols - 1) * col_gap) / cols)
    local cell_h = math.floor((grid_h - (rows - 1) * row_gap) / rows)

    local grid_vgroup = VerticalGroup:new({ align = "center" })
    local start_idx = (page - 1) * per_page + 1

    for r = 1, rows do
        if r > 1 then
            table.insert(grid_vgroup, VerticalSpan:new({ width = row_gap }))
        end
        local hrow = HorizontalGroup:new({ align = "center" })
        for c = 1, cols do
            if c > 1 then
                table.insert(hrow, HorizontalSpan:new({ width = col_gap }))
            end
            local idx = start_idx + (r - 1) * cols + (c - 1)
            local book = filtered[idx]
            if book then
                table.insert(hrow, self:buildBookTile(book, cell_w, cell_h, true))
            else
                table.insert(hrow, HorizontalSpan:new({ width = cell_w }))
            end
        end
        table.insert(grid_vgroup, hrow)
    end

    return VerticalGroup:new({
        align = "center",
        VerticalSpan:new({ width = vgap }),
        ctrl_bar,
        VerticalSpan:new({ width = vgap }),
        grid_vgroup,
    })
end

--- Build Tab 4 (Z-Lib Dedupe Guard) & Tab 5 (Notes & Collections).
function KindleHomeDashboard:buildHubTab(inner_w, body_h, all_books, is_zlib)
    local pad = Screen:scaleBySize(20)
    local card_h = math.floor(body_h * 0.42)
    local vgap = Screen:scaleBySize(16)
    local btn_w = math.min(inner_w - 2 * pad, Screen:scaleBySize(340))
    local btn_h = Screen:scaleBySize(44)

    if is_zlib then
        local guard = self.zlibrary_guard or (self.plugin and self.plugin.zlibrary_guard)
        local card = FrameContainer:new({
            width = inner_w,
            height = card_h,
            margin = 0,
            padding = pad,
            bordersize = Size.border.thin,
            color = Blitbuffer.COLOR_GRAY_7,
            background = Blitbuffer.COLOR_WHITE,
            radius = Screen:scaleBySize(12),
            CenterContainer:new({
                dimen = Geom:new({ w = inner_w - 2 * pad, h = card_h - 2 * pad }),
                VerticalGroup:new({
                    align = "center",
                    TextWidget:new({
                        text = _("🔍 Z-Library Duplicate Guard"),
                        face = Font:getFace("tfont", 20),
                        bold = true,
                    }),
                    VerticalSpan:new({ width = Screen:scaleBySize(10) }),
                    TextBoxWidget:new({
                        text = T(
                            _(
                                "Automatically cross-checks all %1 books on your Kindle (by Title, Author, and ASIN) so you never waste time downloading a duplicate book."
                            ),
                            #all_books
                        ),
                        face = Font:getFace("cfont", 15),
                        width = inner_w - 3 * pad,
                        alignment = "center",
                    }),
                    VerticalSpan:new({ width = Screen:scaleBySize(16) }),
                    makePillButton(
                        _("🔍 Check Kindle Library / Search Z-Library"),
                        btn_w,
                        btn_h,
                        true,
                        safeCallback("Launch ZLib Dialog", function()
                            if guard then
                                guard:showLibraryCheckDialog()
                            else
                                showInfo(_("Z-Library Guard is not initialized."))
                            end
                        end),
                        15
                    ),
                }),
            }),
        })
        return VerticalGroup:new({
            align = "center",
            VerticalSpan:new({ width = vgap }),
            card,
        })
    end

    local notes_card = FrameContainer:new({
        width = inner_w,
        height = card_h,
        margin = 0,
        padding = pad,
        bordersize = Size.border.thin,
        color = Blitbuffer.COLOR_GRAY_7,
        background = Blitbuffer.COLOR_WHITE,
        radius = Screen:scaleBySize(12),
        CenterContainer:new({
            dimen = Geom:new({ w = inner_w - 2 * pad, h = card_h - 2 * pad }),
            VerticalGroup:new({
                align = "center",
                TextWidget:new({
                    text = _("📝 Kindle Highlights & Clippings"),
                    face = Font:getFace("tfont", 19),
                    bold = true,
                }),
                VerticalSpan:new({ width = Screen:scaleBySize(8) }),
                TextBoxWidget:new({
                    text = _("Browse all your Kindle highlights and notes parsed directly from My Clippings.txt and export to Markdown."),
                    face = Font:getFace("cfont", 14),
                    width = inner_w - 3 * pad,
                    alignment = "center",
                }),
                VerticalSpan:new({ width = Screen:scaleBySize(14) }),
                makePillButton(
                    _("📝 Open Highlights Viewer"),
                    btn_w,
                    btn_h,
                    true,
                    safeCallback("Open Highlights", function()
                        if self.highlights_viewer then
                            self.highlights_viewer:show()
                        end
                    end),
                    15
                ),
            }),
        }),
    })

    local coll_card = FrameContainer:new({
        width = inner_w,
        height = card_h,
        margin = 0,
        padding = pad,
        bordersize = Size.border.thin,
        color = Blitbuffer.COLOR_GRAY_7,
        background = Blitbuffer.COLOR_GRAY_E,
        radius = Screen:scaleBySize(12),
        CenterContainer:new({
            dimen = Geom:new({ w = inner_w - 2 * pad, h = card_h - 2 * pad }),
            VerticalGroup:new({
                align = "center",
                TextWidget:new({
                    text = _("📁 Amazon Cloud Collections"),
                    face = Font:getFace("tfont", 19),
                    bold = true,
                }),
                VerticalSpan:new({ width = Screen:scaleBySize(8) }),
                TextBoxWidget:new({
                    text = _("Browse your Kindle collections and synchronize them with KOReader's native collections."),
                    face = Font:getFace("cfont", 14),
                    width = inner_w - 3 * pad,
                    alignment = "center",
                }),
                VerticalSpan:new({ width = Screen:scaleBySize(14) }),
                makePillButton(
                    _("📁 Browse Amazon Collections"),
                    btn_w,
                    btn_h,
                    false,
                    safeCallback("Open Collections", function()
                        self:showCollectionsMenu()
                    end),
                    15
                ),
            }),
        }),
    })

    return VerticalGroup:new({
        align = "center",
        VerticalSpan:new({ width = vgap }),
        notes_card,
        VerticalSpan:new({ width = vgap }),
        coll_card,
    })
end

--- Switch active tab in KindleOS and repaint.
function KindleHomeDashboard:switchTab(tab_id)
    self.current_tab = tab_id or "home"
    self:refreshScreen()
end

--- Open KOReader's native FileChooser for the Kindle Library while ensuring Back/Home returns to KindleOS.
function KindleHomeDashboard:openNativeBrowser()
    local ui = (self.kindle_library and self.kindle_library.ui) or (self.plugin and self.plugin.ui)
    if self.active_menu then
        UIManager:close(self.active_menu)
        self.active_menu = nil
    end
    if self.kindle_library and ui and ui.file_chooser and type(self.kindle_library.show) == "function" then
        self.kindle_library.return_to_dashboard = true
        self.kindle_library:show(ui, false)
    end
end

--- Re-render the active KindleOS full-screen widget in place.
function KindleHomeDashboard:refreshScreen()
    if self.active_menu then
        UIManager:close(self.active_menu)
        self.active_menu = nil
    end
    self:show(self.current_tab)
end

--- Launch and show the primary KindleOS Graphical Home Dashboard.
--- @param initial_tab string|nil
function KindleHomeDashboard:show(initial_tab)
    if type(initial_tab) == "string" and initial_tab ~= "" then
        self.current_tab = initial_tab
    end
    if self.active_menu then
        UIManager:close(self.active_menu)
        self.active_menu = nil
    end

    local sw = Screen:getWidth()
    local sh = Screen:getHeight()
    local side_pad = math.floor(sw * 0.035)
    local inner_w = sw - 2 * side_pad
    local header_h = math.max(44, math.floor(sh * 0.065))
    local nav_h = math.max(52, math.floor(sh * 0.075))
    local body_h = sh - header_h - nav_h

    local all_books = self:getAllBooks()

    local body_widget
    if self.current_tab == "library" then
        body_widget = self:buildGridTab(inner_w, body_h, all_books, false)
    elseif self.current_tab == "manga" then
        local comic_books = {}
        for __, book in ipairs(all_books) do
            if self.manga_mode and self.manga_mode:isComicOrManga(book.source_path) then
                table.insert(comic_books, book)
            end
        end
        body_widget = self:buildGridTab(inner_w, body_h, comic_books, true)
    elseif self.current_tab == "zlib" then
        body_widget = self:buildHubTab(inner_w, body_h, all_books, true)
    elseif self.current_tab == "notes" then
        body_widget = self:buildHubTab(inner_w, body_h, all_books, false)
    else
        self.current_tab = "home"
        body_widget = self:buildHomeTab(inner_w, body_h, all_books)
    end

    local screen_frame = FrameContainer:new({
        width = sw,
        height = sh,
        margin = 0,
        padding = 0,
        bordersize = 0,
        background = Blitbuffer.COLOR_WHITE,
        OverlapGroup:new({
            dimen = Geom:new({ w = sw, h = sh }),
            VerticalGroup:new({
                align = "center",
                self:buildTopBar(sw, header_h, side_pad),
                CenterContainer:new({
                    dimen = Geom:new({ w = sw, h = body_h }),
                    body_widget,
                }),
            }),
            BottomContainer:new({
                dimen = Geom:new({ w = sw, h = sh }),
                self:buildBottomBar(sw, nav_h),
            }),
        }),
    })

    local dashboard_self = self
    local screen_widget = InputContainer:new({
        name = "kindle_os_dashboard",
        dimen = Geom:new({ x = 0, y = 0, w = sw, h = sh }),
        covers_fullscreen = true,
        [1] = screen_frame,
    })
    screen_widget.ges_events = {
        SwipeScreen = {
            GestureRange:new({
                ges = "swipe",
                range = Geom:new({ x = 0, y = 0, w = sw, h = sh }),
            }),
        },
    }
    function screen_widget:onSwipeScreen(__, ges)
        if not ges or not ges.direction then
            return false
        end
        if dashboard_self.current_tab == "library" then
            if ges.direction == "west" then
                dashboard_self.library_page = dashboard_self.library_page + 1
                dashboard_self:refreshScreen()
                return true
            elseif ges.direction == "east" and dashboard_self.library_page > 1 then
                dashboard_self.library_page = dashboard_self.library_page - 1
                dashboard_self:refreshScreen()
                return true
            end
        elseif dashboard_self.current_tab == "home" then
            if ges.direction == "west" then
                dashboard_self.shelf_page = dashboard_self.shelf_page + 1
                dashboard_self:refreshScreen()
                return true
            elseif ges.direction == "east" and dashboard_self.shelf_page > 1 then
                dashboard_self.shelf_page = dashboard_self.shelf_page - 1
                dashboard_self:refreshScreen()
                return true
            end
        end
        return false
    end
    function screen_widget:onCloseWidget()
        if self[1] and type(self[1].free) == "function" then
            self[1]:free()
        end
        UIManager:setDirty(nil, "full")
    end

    self.active_menu = screen_widget
    UIManager:show(self.active_menu)
    UIManager:setDirty(self.active_menu, "full")
end

--- Show a paginated book catalog for a given list of books.
--- @param title string
--- @param book_list table
function KindleHomeDashboard:showLibraryCatalog(title, book_list)
    local items = {}
    local catalog_menu

    for __, book in ipairs(book_list) do
        local book_title = tostring(book.title or _("Untitled"))
        local authors_str = formatAuthors(book.authors or book.author)
        local author = authors_str ~= "" and (" — " .. authors_str) or ""
        local pct = tonumber(book.percent_finished)
        local percent = _("Unread")
        if pct and pct > 0 then
            percent = string.format("%d%%", pct <= 1 and math.floor(pct * 100) or math.floor(pct))
        end
        local is_comic = self.manga_mode and self.manga_mode:isComicOrManga(book.source_path)
        local badge = is_comic and " [Comic]" or ""

        table.insert(items, {
            text = book_title .. badge .. author,
            help_text = T(_("Progress: %1 • Path: %2"), percent, book.source_path or ""),
            callback = safeCallback("Open Catalog Book", function()
                if catalog_menu then
                    UIManager:close(catalog_menu)
                end
                self:openBook(book)
            end),
        })
    end

    if #items == 0 then
        table.insert(items, {
            text = _("No books found in this category."),
            callback = function() end,
        })
    end

    catalog_menu = Menu:new({
        title = T(_("%1 (%2)"), title, #book_list),
        item_table = items,
    })

    UIManager:show(catalog_menu)
end

--- Show collections menu.
function KindleHomeDashboard:showCollectionsMenu()
    if not self.collections_sync then
        showInfo(_("Collections sync not initialized."))
        return
    end

    local collections, err = self.collections_sync:getKindleCollections()
    if not collections or #collections == 0 then
        showInfo(err or _("No Kindle collections found in cc.db."))
        return
    end

    local items = {}
    for __, coll in ipairs(collections) do
        local count = coll.books and #coll.books or 0
        table.insert(items, {
            text = T(_("📁 %1 (%2 books)"), coll.name, count),
            callback = safeCallback("Open Collection", function()
                local books = {}
                for __idx, path in ipairs(coll.books) do
                    local b = self.virtual_library and self.virtual_library:getBook(path)
                    table.insert(books, b or { title = path:match("([^/]+)$"), source_path = path })
                end
                self:showLibraryCatalog(coll.name, books)
            end),
        })
    end

    local coll_menu = Menu:new({
        title = T(_("Amazon Collections (%1)"), #collections),
        item_table = items,
    })

    UIManager:show(coll_menu)
end

return KindleHomeDashboard
