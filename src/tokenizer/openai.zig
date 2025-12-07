const std = @import("std");

/// Basis tokenizer ID voor OpenAI-achtige modellen.
/// Eén base-tokenizer kan door meerdere "modelnamen" gebruikt worden.
pub const BaseTokenizer = enum {
    cl100k_base,
    o200k_base,
};

/// Publieke API voor de OpenAI-tokenizerlaag.
/// De bedoeling is dat hogere lagen een BaseTokenizer kiezen op basis van modelnaam.
pub const OpenAITokenizer = struct {
    base: BaseTokenizer,

    /// In v1 gebruiken we geen heap tijdens tokenization.
    /// In init kun je later embedded tabellen initialiseren.
    pub fn init(base: BaseTokenizer) OpenAITokenizer {
        return .{ .base = base };
    }

    /// Count tokens for a single text segment.
    /// Voor nu: placeholder implementatie, zodat je flow kunt testen.
    pub fn countTokens(self: OpenAITokenizer, text: []const u8) usize {
        _ = self;

        // TODO: vervang dit door echte BPE tokenization met embedded rank tables.
        // Voor nu: gebruik een simpele word-count als "dummy".
        return simpleWordLikeCount(text);
    }

    /// Straks kun je hier een helper maken die ook systeem-/user-/assistant-messages
    /// meeneemt zoals OpenAI's chat-format dat doet.
    pub fn countChatTokens(
        self: OpenAITokenizer,
        messages_json: []const u8,
    ) !usize {
        _ = self;
        _ = messages_json;

        // TODO: parse JSON, itereren over messages, per content token count.
        return error.NotImplemented;
    }
};

/// Dummy-implementatie: tel woorden zoals in cli/commands.zig.
/// Later vervang je dit volledige bestand door een BPE-implementatie.
fn simpleWordLikeCount(text: []const u8) usize {
    var in_word = false;
    var count: usize = 0;

    for (text) |c| {
        const is_space = std.ascii.isWhitespace(c);
        if (!is_space and !in_word) {
            in_word = true;
            count += 1;
        } else if (is_space) {
            in_word = false;
        }
    }
    return count;
}
