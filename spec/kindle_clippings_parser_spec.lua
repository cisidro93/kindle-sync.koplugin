-- Tests for KindleClippingsParser module

require("busted.runner")()
local helper = require("spec/test_helper")

describe("KindleClippingsParser", function()
    local KindleClippingsParser

    local SAMPLE_CLIPPINGS = [[
The Chronicles of Narnia Complete 7-Book Collection (Lewis, C. S.)
- Your Highlight on page 216 | Location 3160-3160 | Added on Thursday, January 16, 2025 9:29:16 PM

stone? If she can stand on her two feet and
==========
Mindset (Carol S. Dweck)
- Your Highlight on page 15 | Location 299-299 | Added on Thursday, July 3, 2025 7:52:43 PM

the world of fixed traits-success is about proving you're smart or talented. Validating yourself
==========
Mindset (Carol S. Dweck)
- Your Highlight on page 15 | Location 300-301 | Added on Thursday, July 3, 2025 7:53:18 PM

the world of changing qualities-it's about stretching yourself to learn something new. Developing yourself.
==========
Book Without Author
- Your Note on Location 50 | Added on Friday, August 1, 2025 10:00:00 AM

My private note on this passage.
==========
]]

    setup(function()
        helper.setup_complete()
        KindleClippingsParser = require("lua/lib/kindle_clippings_parser")
    end)

    before_each(function()
        helper.before_each()
    end)

    describe("parseContent", function()
        it("should parse structured clippings from sample text", function()
            local list, by_book = KindleClippingsParser.parseContent(SAMPLE_CLIPPINGS)

            assert.equals(4, #list)

            local narnia = list[1]
            assert.equals("The Chronicles of Narnia Complete 7-Book Collection", narnia.title)
            assert.equals("Lewis, C. S.", narnia.author)
            assert.equals("highlight", narnia.type)
            assert.equals(216, narnia.page)
            assert.equals(3160, narnia.loc_start)
            assert.equals(3160, narnia.loc_end)
            assert.equals("stone? If she can stand on her two feet and", narnia.text)

            local mindset1 = list[2]
            assert.equals("Mindset", mindset1.title)
            assert.equals("Carol S. Dweck", mindset1.author)
            assert.equals(15, mindset1.page)
            assert.equals(299, mindset1.loc_start)

            local note = list[4]
            assert.equals("Book Without Author", note.title)
            assert.equals("", note.author)
            assert.equals("note", note.type)
            assert.equals(50, note.loc_start)
            assert.equals("My private note on this passage.", note.text)

            -- Grouped by book check
            assert.is_not_nil(by_book["mindset"])
            assert.equals(2, #by_book["mindset"].clippings)
        end)
    end)

    describe("getClippingsForBook", function()
        it("should find clippings matching book title or substring", function()
            local parser = KindleClippingsParser:new("/mnt/us/documents/My Clippings.txt")
            parser.cached_clippings = {
                list = {},
                by_book = select(2, KindleClippingsParser.parseContent(SAMPLE_CLIPPINGS)),
            }

            local clips = parser:getClippingsForBook({ title = "Mindset" })
            assert.equals(2, #clips)

            local narnia_clips = parser:getClippingsForBook({ title = "The Chronicles of Narnia" })
            assert.equals(1, #narnia_clips)

            local missing = parser:getClippingsForBook({ title = "Nonexistent Book" })
            assert.equals(0, #missing)
        end)
    end)
end)
