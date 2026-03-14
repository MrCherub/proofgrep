const std = @import("std");
const builtin = @import("builtin");

const Allocator = std.mem.Allocator;
const FileType = enum { all, md, tex, lean, txt, typ, sty };
const Command = enum { default_chat, find, ask, chat, help };

const Nord = struct {
    const path = "38;2;136;192;208";
    const line = "38;2;180;142;173";
    const match = "38;2;235;203;139";
    const context = "38;2;216;222;233";
    const separator = "38;2;94;129;172";
    const title = "38;2;163;190;140";
    const muted = "38;2;129;161;193";
    const reset = "0";
};

const default_roots = [_][]const u8{
    "~/ObsidianVault",
    "~/Developer/latex",
    "~/Developer/logicbox",
    "~/Documents/latex",
};

const stopwords = [_][]const u8{
    "a",      "about", "an",   "and",  "are",   "can",   "do",   "does", "file", "files",
    "find",   "for",   "from", "give", "how",   "i",     "in",   "is",   "it",   "known",
    "locate", "me",    "my",   "of",   "on",    "open",  "or",   "path", "pull", "say",
    "show",   "tell",  "that", "the",  "their", "these", "this", "to",   "what", "where",
    "which",  "who",   "why",  "with", "your",
};

const SearchOptions = struct {
    file_type: FileType = .all,
    hidden: bool = false,
    context: usize = 1,
    limit: usize = 8,
    ignore_case: bool = false,
    literal: bool = false,
};

const Parsed = struct {
    command: Command,
    query: ?[]const u8 = null,
    paths: [][]const u8 = &.{},
    options: SearchOptions = .{},
};

const ContextLine = struct {
    line_number: usize,
    text: []const u8,
};

const QuestionHit = struct {
    path: []const u8,
    line_number: usize,
    line_text: []const u8,
    before: []ContextLine,
    after: []ContextLine,
    score: i32,
    matched_terms: [][]const u8,
};

const SearchState = struct {
    arena: Allocator,
    scratch: Allocator,
    hits: *std.ArrayList(QuestionHit),
    terms: [][]const u8,
    normalized_phrase: []const u8,
    file_intent: bool,
    context: usize,
};

fn useColor() bool {
    if (std.process.hasEnvVarConstant("FORCE_COLOR")) return true;
    if (std.process.hasEnvVarConstant("NO_COLOR")) return false;
    return std.posix.isatty(std.fs.File.stdout().handle);
}

fn paint(writer: *std.Io.Writer, enabled: bool, color: []const u8, text: []const u8) !void {
    if (!enabled) {
        try writer.writeAll(text);
        return;
    }
    try writer.print("\x1b[{s}m{s}\x1b[{s}m", .{ color, text, Nord.reset });
}

fn printlnColor(writer: *std.Io.Writer, enabled: bool, color: []const u8, text: []const u8) !void {
    try paint(writer, enabled, color, text);
    try writer.writeByte('\n');
}

fn fileTypeExtension(ft: FileType) ?[]const u8 {
    return switch (ft) {
        .all => null,
        .md => ".md",
        .tex => ".tex",
        .lean => ".lean",
        .txt => ".txt",
        .typ => ".typ",
        .sty => ".sty",
    };
}

fn isAllowedExtension(path: []const u8, ft: FileType) bool {
    const ext = std.fs.path.extension(path);
    if (ft != .all) return std.ascii.eqlIgnoreCase(ext, fileTypeExtension(ft).?);
    return std.ascii.eqlIgnoreCase(ext, ".md") or
        std.ascii.eqlIgnoreCase(ext, ".markdown") or
        std.ascii.eqlIgnoreCase(ext, ".txt") or
        std.ascii.eqlIgnoreCase(ext, ".tex") or
        std.ascii.eqlIgnoreCase(ext, ".lean") or
        std.ascii.eqlIgnoreCase(ext, ".typ") or
        std.ascii.eqlIgnoreCase(ext, ".sty");
}

fn hasHiddenComponent(path: []const u8) bool {
    var it = std.mem.splitScalar(u8, path, std.fs.path.sep);
    while (it.next()) |part| {
        if (part.len == 0) continue;
        if (part[0] == '.') return true;
    }
    return false;
}

fn isWordChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '+' or c == '_' or c == '-';
}

fn isStopword(term: []const u8) bool {
    for (stopwords) |word| {
        if (std.mem.eql(u8, term, word)) return true;
    }
    return false;
}

fn lowerOwned(allocator: Allocator, text: []const u8) ![]u8 {
    const out = try allocator.alloc(u8, text.len);
    for (text, 0..) |c, i| out[i] = std.ascii.toLower(c);
    return out;
}

fn normalizeForPhrase(allocator: Allocator, text: []const u8) ![]u8 {
    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(allocator);

    var last_space = true;
    for (text) |c| {
        const lower = std.ascii.toLower(c);
        if (std.ascii.isAlphanumeric(lower) or lower == '+' or lower == '_') {
            try list.append(allocator, lower);
            last_space = false;
        } else if (lower == '-' or std.ascii.isWhitespace(lower)) {
            if (!last_space and list.items.len > 0) {
                try list.append(allocator, ' ');
                last_space = true;
            }
        }
    }

    if (list.items.len > 0 and list.items[list.items.len - 1] == ' ') _ = list.pop();
    return list.toOwnedSlice(allocator);
}

fn extractTerms(allocator: Allocator, query: []const u8) ![][]const u8 {
    const lower = try lowerOwned(allocator, query);
    defer allocator.free(lower);

    var list: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (list.items) |item| allocator.free(item);
        list.deinit(allocator);
    }

    var start: ?usize = null;
    for (lower, 0..) |c, i| {
        if (isWordChar(c)) {
            if (start == null) start = i;
        } else if (start) |s| {
            const term = lower[s..i];
            if (term.len > 1 and !isStopword(term)) {
                var duplicate = false;
                for (list.items) |existing| {
                    if (std.mem.eql(u8, existing, term)) {
                        duplicate = true;
                        break;
                    }
                }
                if (!duplicate) try list.append(allocator, try allocator.dupe(u8, term));
            }
            start = null;
        }
    }

    if (start) |s| {
        const term = lower[s..];
        if (term.len > 1 and !isStopword(term)) {
            var duplicate = false;
            for (list.items) |existing| {
                if (std.mem.eql(u8, existing, term)) {
                    duplicate = true;
                    break;
                }
            }
            if (!duplicate) try list.append(allocator, try allocator.dupe(u8, term));
        }
    }

    return list.toOwnedSlice(allocator);
}

fn queryHasFileIntent(query: []const u8) bool {
    const words = [_][]const u8{ "file", "files", "path", "locate", "open" };
    var it = std.mem.tokenizeAny(u8, query, " \t\r\n");
    while (it.next()) |part| {
        for (words) |word| {
            if (std.ascii.eqlIgnoreCase(part, word)) return true;
        }
    }
    return false;
}

fn scoreLine(line_lower: []const u8, terms: [][]const u8, normalized_line: []const u8, normalized_phrase: []const u8, matched_terms: *std.ArrayList([]const u8), allocator: Allocator) !i32 {
    var score: i32 = 0;
    for (terms) |term| {
        if (std.mem.indexOf(u8, line_lower, term) != null) {
            try matched_terms.append(allocator, term);
            score += 14;
        }
    }
    if (normalized_phrase.len > 0 and std.mem.indexOf(u8, normalized_line, normalized_phrase) != null) {
        score += 24;
    }
    const trimmed = std.mem.trimLeft(u8, line_lower, " \t");
    if (trimmed.len > 0 and trimmed[0] == '#') score += 6;
    return score;
}

fn scorePath(path_lower: []const u8, terms: [][]const u8, normalized_path: []const u8, normalized_phrase: []const u8, file_intent: bool, matched_terms: *std.ArrayList([]const u8), allocator: Allocator) !i32 {
    const base = std.fs.path.basename(path_lower);
    const stem = base[0 .. base.len - std.fs.path.extension(base).len];
    var score: i32 = 0;

    if (normalized_phrase.len > 0 and std.mem.indexOf(u8, normalized_path, normalized_phrase) != null) {
        score += if (file_intent) 60 else 36;
    }

    for (terms) |term| {
        if (std.mem.eql(u8, stem, term)) {
            score += if (file_intent) 72 else 42;
            try matched_terms.append(allocator, term);
        } else if (std.mem.indexOf(u8, base, term) != null) {
            score += if (file_intent) 28 else 16;
            try matched_terms.append(allocator, term);
        } else if (std.mem.indexOf(u8, path_lower, term) != null) {
            score += if (file_intent) 10 else 6;
            try matched_terms.append(allocator, term);
        }
    }

    if (file_intent and isAllowedExtension(path_lower, .all)) score += 8;
    return score;
}

fn sortLess(_: void, a: QuestionHit, b: QuestionHit) bool {
    if (a.score != b.score) return a.score > b.score;
    const order = std.mem.order(u8, a.path, b.path);
    if (order != .eq) return order == .lt;
    return a.line_number < b.line_number;
}

fn collectLines(allocator: Allocator, content: []u8) ![][]const u8 {
    var list: std.ArrayList([]const u8) = .empty;
    defer list.deinit(allocator);
    var it = std.mem.splitScalar(u8, content, '\n');
    while (it.next()) |line| {
        const trimmed = if (line.len > 0 and line[line.len - 1] == '\r') line[0 .. line.len - 1] else line;
        try list.append(allocator, trimmed);
    }
    return list.toOwnedSlice(allocator);
}

fn dupContextLines(arena: Allocator, lines: []const []const u8, start_idx: usize, end_idx: usize) ![]ContextLine {
    var list: std.ArrayList(ContextLine) = .empty;
    defer list.deinit(arena);
    for (start_idx..end_idx) |idx| {
        try list.append(arena, .{ .line_number = idx + 1, .text = try arena.dupe(u8, lines[idx]) });
    }
    return list.toOwnedSlice(arena);
}

fn expandHome(allocator: Allocator, raw: []const u8) ![]const u8 {
    if (std.mem.startsWith(u8, raw, "~/")) {
        const home = std.process.getEnvVarOwned(allocator, "HOME") catch return allocator.dupe(u8, raw);
        defer allocator.free(home);
        return std.fs.path.join(allocator, &.{ home, raw[2..] });
    }
    return allocator.dupe(u8, raw);
}

fn realishPath(allocator: Allocator, raw: []const u8) ![]const u8 {
    const expanded = try expandHome(allocator, raw);
    defer allocator.free(expanded);
    if (std.fs.path.isAbsolute(expanded)) return allocator.dupe(u8, expanded);
    return std.fs.cwd().realpathAlloc(allocator, expanded) catch allocator.dupe(u8, expanded);
}

fn addSearchPath(list: *std.ArrayList([]const u8), allocator: Allocator, raw: []const u8) !void {
    try list.append(allocator, try realishPath(allocator, raw));
}

fn parseFileType(value: []const u8) !FileType {
    if (std.mem.eql(u8, value, "all")) return .all;
    if (std.mem.eql(u8, value, "md")) return .md;
    if (std.mem.eql(u8, value, "tex")) return .tex;
    if (std.mem.eql(u8, value, "lean")) return .lean;
    if (std.mem.eql(u8, value, "txt")) return .txt;
    if (std.mem.eql(u8, value, "typ")) return .typ;
    if (std.mem.eql(u8, value, "sty")) return .sty;
    return error.InvalidFileType;
}

fn printHelp(writer: *std.Io.Writer) !void {
    try writer.writeAll(
        "proofgrep\n\n" ++
        "Usage:\n" ++
        "  proofgrep\n" ++
        "  proofgrep find <query> [paths...] [--type <kind>] [--context <n>] [--ignore-case] [--literal] [--hidden]\n" ++
        "  proofgrep ask <query> [paths...] [--type <kind>] [--context <n>] [--limit <n>] [--hidden]\n" ++
        "  proofgrep chat [paths...] [--type <kind>] [--context <n>] [--limit <n>] [--hidden]\n\n" ++
        "Examples:\n" ++
        "  proofgrep\n" ++
        "  proofgrep ask \"What do my notes say about Navier-Stokes?\"\n" ++
        "  proofgrep find theorem ~/Developer/logicbox --type tex --context 1\n",
    );
}

fn parseArgs(allocator: Allocator) !Parsed {
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len == 1) return .{ .command = .default_chat };

    var parsed = Parsed{ .command = .default_chat };
    var positionals: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (positionals.items) |item| allocator.free(item);
        positionals.deinit(allocator);
    }

    var idx: usize = 1;
    const sub = args[idx];
    if (std.mem.eql(u8, sub, "find")) {
        parsed.command = .find;
        idx += 1;
    } else if (std.mem.eql(u8, sub, "ask")) {
        parsed.command = .ask;
        idx += 1;
    } else if (std.mem.eql(u8, sub, "chat")) {
        parsed.command = .chat;
        idx += 1;
    } else if (std.mem.eql(u8, sub, "-h") or std.mem.eql(u8, sub, "--help")) {
        return .{ .command = .help };
    }

    while (idx < args.len) : (idx += 1) {
        const arg = args[idx];
        if (std.mem.eql(u8, arg, "--hidden")) {
            parsed.options.hidden = true;
        } else if (std.mem.eql(u8, arg, "--ignore-case")) {
            parsed.options.ignore_case = true;
        } else if (std.mem.eql(u8, arg, "--literal")) {
            parsed.options.literal = true;
        } else if (std.mem.eql(u8, arg, "--type")) {
            idx += 1;
            if (idx >= args.len) return error.MissingOptionValue;
            parsed.options.file_type = try parseFileType(args[idx]);
        } else if (std.mem.eql(u8, arg, "--context")) {
            idx += 1;
            if (idx >= args.len) return error.MissingOptionValue;
            parsed.options.context = try std.fmt.parseInt(usize, args[idx], 10);
        } else if (std.mem.eql(u8, arg, "--limit")) {
            idx += 1;
            if (idx >= args.len) return error.MissingOptionValue;
            parsed.options.limit = try std.fmt.parseInt(usize, args[idx], 10);
        } else {
            try positionals.append(allocator, try allocator.dupe(u8, arg));
        }
    }

    switch (parsed.command) {
        .find, .ask => {
            if (positionals.items.len == 0) return error.MissingQuery;
            parsed.query = positionals.items[0];
            parsed.paths = positionals.items[1..];
        },
        .chat, .default_chat => parsed.paths = positionals.items,
        .help => {},
    }

    return parsed;
}

fn processQuestionFile(path: []const u8, state: *SearchState) !void {
    const file = std.fs.openFileAbsolute(path, .{}) catch return;
    defer file.close();

    const stat = try file.stat();
    if (stat.size > 4 * 1024 * 1024) return;

    const content = try file.readToEndAlloc(state.scratch, @intCast(stat.size + 1));
    defer state.scratch.free(content);

    const lines = try collectLines(state.scratch, content);
    defer state.scratch.free(lines);

    const path_lower = try lowerOwned(state.scratch, path);
    defer state.scratch.free(path_lower);
    const normalized_path = try normalizeForPhrase(state.scratch, path);
    defer state.scratch.free(normalized_path);

    var path_terms: std.ArrayList([]const u8) = .empty;
    defer path_terms.deinit(state.scratch);
    const path_score = try scorePath(path_lower, state.terms, normalized_path, state.normalized_phrase, state.file_intent, &path_terms, state.scratch);
    if (path_score > 0) {
        try state.hits.append(state.arena, .{
            .path = try state.arena.dupe(u8, path),
            .line_number = 1,
            .line_text = try std.fmt.allocPrint(state.arena, "file match: {s}", .{std.fs.path.basename(path)}),
            .before = &.{},
            .after = &.{},
            .score = path_score,
            .matched_terms = try state.arena.dupe([]const u8, path_terms.items),
        });
    }

    for (lines, 0..) |line, idx| {
        const line_lower = try lowerOwned(state.scratch, line);
        defer state.scratch.free(line_lower);
        const normalized_line = try normalizeForPhrase(state.scratch, line);
        defer state.scratch.free(normalized_line);

        var matched_terms: std.ArrayList([]const u8) = .empty;
        defer matched_terms.deinit(state.scratch);
        const score = try scoreLine(line_lower, state.terms, normalized_line, state.normalized_phrase, &matched_terms, state.scratch);
        if (score == 0) continue;

        const before_start = idx -| state.context;
        const after_end = @min(lines.len, idx + 1 + state.context);

        try state.hits.append(state.arena, .{
            .path = try state.arena.dupe(u8, path),
            .line_number = idx + 1,
            .line_text = try state.arena.dupe(u8, line),
            .before = try dupContextLines(state.arena, lines, before_start, idx),
            .after = try dupContextLines(state.arena, lines, idx + 1, after_end),
            .score = score,
            .matched_terms = try state.arena.dupe([]const u8, matched_terms.items),
        });
    }
}

fn searchRoot(path: []const u8, options: SearchOptions, state: *SearchState) !void {
    var dir = std.fs.openDirAbsolute(path, .{ .iterate = true }) catch {
        if (std.fs.openFileAbsolute(path, .{})) |file| {
            defer file.close();
            if ((!options.hidden or !hasHiddenComponent(path)) and isAllowedExtension(path, options.file_type)) {
                try processQuestionFile(path, state);
            }
        } else |_| {}
        return;
    };
    defer dir.close();

    var walker = try dir.walk(state.scratch);
    defer walker.deinit();

    while (try walker.next()) |entry| {
        if (entry.kind != .file) continue;
        if (!options.hidden and hasHiddenComponent(entry.path)) continue;
        const full = try std.fs.path.join(state.scratch, &.{ path, entry.path });
        defer state.scratch.free(full);
        if (!isAllowedExtension(full, options.file_type)) continue;
        try processQuestionFile(full, state);
    }
}

fn searchQuestion(arena: Allocator, scratch: Allocator, query: []const u8, paths: [][]const u8, options: SearchOptions) ![]QuestionHit {
    var terms = try extractTerms(arena, query);
    if (terms.len == 0) {
        const lower = try lowerOwned(arena, query);
        const single = try arena.alloc([]const u8, 1);
        single[0] = lower;
        terms = single;
    }

    const normalized_phrase = try normalizeForPhrase(arena, query);
    var hits: std.ArrayList(QuestionHit) = .empty;
    var state = SearchState{
        .arena = arena,
        .scratch = scratch,
        .hits = &hits,
        .terms = terms,
        .normalized_phrase = normalized_phrase,
        .file_intent = queryHasFileIntent(query),
        .context = options.context,
    };

    for (paths) |path| try searchRoot(path, options, &state);

    std.sort.block(QuestionHit, hits.items, {}, sortLess);
    if (hits.items.len > options.limit) return hits.items[0..options.limit];
    return hits.items;
}

fn spawnCommand(allocator: Allocator, argv: []const []const u8) !u8 {
    var child = std.process.Child.init(argv, allocator);
    child.stdin_behavior = .Inherit;
    child.stdout_behavior = .Inherit;
    child.stderr_behavior = .Inherit;
    const term = try child.spawnAndWait();
    return switch (term) {
        .Exited => |code| code,
        else => 1,
    };
}

fn openHit(allocator: Allocator, path: []const u8) !u8 {
    const nvim_argv = [_][]const u8{ "nvim", path };
    return spawnCommand(allocator, &nvim_argv) catch |err| switch (err) {
        error.FileNotFound => {
            if (std.process.getEnvVarOwned(allocator, "EDITOR")) |editor| {
                defer allocator.free(editor);
                var argv: std.ArrayList([]const u8) = .empty;
                defer argv.deinit(allocator);
                var split = std.mem.tokenizeAny(u8, editor, " \t");
                while (split.next()) |part| try argv.append(allocator, try allocator.dupe(u8, part));
                try argv.append(allocator, path);
                return spawnCommand(allocator, argv.items) catch 1;
            } else |_| {
                const fallback = if (builtin.os.tag == .macos)
                    [_][]const u8{ "open", path }
                else
                    [_][]const u8{ "xdg-open", path };
                return spawnCommand(allocator, &fallback) catch 1;
            }
        },
        else => return err,
    };
}

fn printFormattedLine(writer: *std.Io.Writer, colors: bool, path: []const u8, line_number: usize, text: []const u8, is_match: bool) !void {
    try paint(writer, colors, if (is_match) Nord.match else Nord.separator, if (is_match) ">" else "-");
    try writer.writeByte(' ');
    try paint(writer, colors, Nord.path, path);
    try writer.writeByte(':');
    var buf: [32]u8 = undefined;
    const ln = try std.fmt.bufPrint(&buf, "{d}", .{line_number});
    try paint(writer, colors, Nord.line, ln);
    try writer.writeByte(':');
    try paint(writer, colors, if (is_match) Nord.match else Nord.context, text);
    try writer.writeByte('\n');
}

fn printQuestionResults(writer: *std.Io.Writer, colors: bool, query: []const u8, hits: []QuestionHit) !u8 {
    if (hits.len == 0) {
        try printlnColor(writer, colors, Nord.muted, "No relevant notes found.");
        return 1;
    }

    try paint(writer, colors, Nord.title, "Query: ");
    try paint(writer, colors, Nord.context, query);
    try writer.writeByte('\n');

    var last_path: ?[]const u8 = null;
    for (hits, 0..) |hit, idx| {
        if (last_path == null or !std.mem.eql(u8, last_path.?, hit.path)) {
            if (last_path != null) try writer.writeByte('\n');
            try paint(writer, colors, Nord.muted, "[");
            try writer.print("{d}", .{idx + 1});
            try paint(writer, colors, Nord.muted, "] ");
            try paint(writer, colors, Nord.path, hit.path);
            try writer.writeByte('\n');
            last_path = hit.path;
        } else {
            try paint(writer, colors, Nord.muted, "[");
            try writer.print("{d}", .{idx + 1});
            try paint(writer, colors, Nord.muted, "]");
            try writer.writeByte('\n');
        }

        for (hit.before) |ctx| try printFormattedLine(writer, colors, hit.path, ctx.line_number, ctx.text, false);
        try printFormattedLine(writer, colors, hit.path, hit.line_number, hit.line_text, true);
        for (hit.after) |ctx| try printFormattedLine(writer, colors, hit.path, ctx.line_number, ctx.text, false);

        const terms_text = if (hit.matched_terms.len > 0) hit.matched_terms[0] else "phrase";
        try paint(writer, colors, Nord.muted, "  score=");
        try writer.print("{d}", .{hit.score});
        try paint(writer, colors, Nord.muted, " terms=");
        try paint(writer, colors, Nord.muted, terms_text);
        try writer.writeByte('\n');
    }
    return 0;
}

fn buildPattern(allocator: Allocator, query: []const u8, literal: bool) ![]const u8 {
    if (literal) return allocator.dupe(u8, query);

    var words = std.mem.tokenizeAny(u8, query, " \t\r\n");
    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(allocator);
    var first = true;
    while (words.next()) |word| {
        if (!first) try list.appendSlice(allocator, "[-\\s]+");
        first = false;
        for (word) |c| {
            if (std.mem.indexOfScalar(u8, "\\.+*?()[]{}^$|", c) != null) try list.append(allocator, '\\');
            try list.append(allocator, c);
        }
    }
    if (list.items.len == 0) return allocator.dupe(u8, query);
    return list.toOwnedSlice(allocator);
}

fn runFind(allocator: Allocator, parsed: Parsed) !u8 {
    var paths: std.ArrayList([]const u8) = .empty;
    defer paths.deinit(allocator);
    if (parsed.paths.len == 0) {
        try addSearchPath(&paths, allocator, ".");
    } else {
        for (parsed.paths) |path| try addSearchPath(&paths, allocator, path);
    }

    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(allocator);
    try argv.append(allocator, "rg");
    try argv.append(allocator, "--line-number");
    try argv.append(allocator, "--color=never");
    if (parsed.options.context > 0) {
        try argv.append(allocator, "--context");
        try argv.append(allocator, try std.fmt.allocPrint(allocator, "{d}", .{parsed.options.context}));
    }
    if (parsed.options.hidden) try argv.append(allocator, "--hidden");
    if (parsed.options.ignore_case) try argv.append(allocator, "--ignore-case");
    if (parsed.options.literal) {
        try argv.append(allocator, "--fixed-strings");
        try argv.append(allocator, parsed.query.?);
    } else {
        try argv.append(allocator, "--pcre2");
        try argv.append(allocator, try buildPattern(allocator, parsed.query.?, false));
    }

    if (parsed.options.file_type != .all) {
        try argv.append(allocator, "-g");
        try argv.append(allocator, try std.fmt.allocPrint(allocator, "*{s}", .{fileTypeExtension(parsed.options.file_type).?}));
    } else {
        const globs = [_][]const u8{ "*.md", "*.markdown", "*.txt", "*.tex", "*.lean", "*.typ", "*.sty" };
        for (globs) |glob| {
            try argv.append(allocator, "-g");
            try argv.append(allocator, glob);
        }
    }

    for (paths.items) |path| try argv.append(allocator, path);
    return spawnCommand(allocator, argv.items);
}

fn buildSearchPaths(allocator: Allocator, raw_paths: [][]const u8) ![][]const u8 {
    var list: std.ArrayList([]const u8) = .empty;
    if (raw_paths.len > 0) {
        for (raw_paths) |path| try addSearchPath(&list, allocator, path);
    } else {
        for (default_roots) |path| addSearchPath(&list, allocator, path) catch {};
    }
    return list.toOwnedSlice(allocator);
}

fn runAsk(allocator: Allocator, parsed: Parsed) !u8 {
    var scratch_arena = std.heap.ArenaAllocator.init(allocator);
    defer scratch_arena.deinit();
    var result_arena = std.heap.ArenaAllocator.init(allocator);
    defer result_arena.deinit();

    const paths = try buildSearchPaths(scratch_arena.allocator(), parsed.paths);
    const hits = try searchQuestion(result_arena.allocator(), scratch_arena.allocator(), parsed.query.?, paths, parsed.options);
    var out_file_writer = std.fs.File.stdout().writer(&.{});
    return printQuestionResults(&out_file_writer.interface, useColor(), parsed.query.?, hits);
}

fn runChat(allocator: Allocator, parsed: Parsed) !u8 {
    const colors = useColor();
    var out_file_writer = std.fs.File.stdout().writer(&.{});
    const out = &out_file_writer.interface;
    try printlnColor(out, colors, Nord.title, "∀ ∃ proofgrep");
    try printlnColor(out, colors, Nord.muted, "Ask about your notes. Type :q to quit.");
    try printlnColor(out, colors, Nord.muted, "Type a result number to open that file.");

    var path_arena = std.heap.ArenaAllocator.init(allocator);
    defer path_arena.deinit();
    const paths = try buildSearchPaths(path_arena.allocator(), parsed.paths);

    var result_arena = std.heap.ArenaAllocator.init(allocator);
    defer result_arena.deinit();
    var last_hits: []QuestionHit = &.{};

    var stdin_buf: [4096]u8 = undefined;
    var stdin_reader = std.fs.File.stdin().reader(&stdin_buf);

    while (true) {
        try paint(out, colors, Nord.match, "proofgrep> ");
        const maybe_line = try stdin_reader.interface.takeDelimiter('\n');
        if (maybe_line == null) {
            try out.writeByte('\n');
            return 0;
        }
        const query = std.mem.trim(u8, maybe_line.?, " \t\r\n");
        if (query.len == 0) continue;
        if (std.mem.eql(u8, query, ":q") or std.mem.eql(u8, query, "quit") or std.mem.eql(u8, query, "exit")) return 0;
        if (std.mem.eql(u8, query, ":help") or std.mem.eql(u8, query, "help")) {
            try out.writeAll("Type a question like: What do my notes say about Navier-Stokes?\n");
            try out.writeAll("After results appear, type a number like 1 to open that file.\n");
            continue;
        }

        if (std.fmt.parseInt(usize, query, 10)) |index| {
            if (last_hits.len == 0) {
                try printlnColor(out, colors, Nord.muted, "No previous results to open.");
                continue;
            }
            if (index == 0 or index > last_hits.len) {
                try paint(out, colors, Nord.muted, "No result ");
                try out.print("{d}", .{index});
                try paint(out, colors, Nord.muted, ".");
                try out.writeByte('\n');
                continue;
            }
            const hit = last_hits[index - 1];
            try paint(out, colors, Nord.title, "Opening ");
            try paint(out, colors, Nord.path, hit.path);
            try out.writeByte('\n');
            const rc = try openHit(allocator, hit.path);
            if (rc != 0) try printlnColor(out, colors, Nord.muted, "Failed to open result.");
            continue;
        } else |_| {}

        result_arena.deinit();
        result_arena = std.heap.ArenaAllocator.init(allocator);
        var scratch_arena = std.heap.ArenaAllocator.init(allocator);
        defer scratch_arena.deinit();
        last_hits = try searchQuestion(result_arena.allocator(), scratch_arena.allocator(), query, paths, parsed.options);
        _ = try printQuestionResults(out, colors, query, last_hits);
        try out.writeByte('\n');
    }
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const parsed = parseArgs(allocator) catch |err| {
        if (err == error.MissingQuery or err == error.MissingOptionValue or err == error.InvalidFileType) {
            var err_writer = std.fs.File.stderr().writer(&.{});
            try printHelp(&err_writer.interface);
            std.process.exit(2);
        }
        return err;
    };

    if (parsed.command == .help) {
        var out_writer = std.fs.File.stdout().writer(&.{});
        try printHelp(&out_writer.interface);
        return;
    }

    if (parsed.command == .default_chat and !std.posix.isatty(std.fs.File.stdin().handle)) {
        var err_writer2 = std.fs.File.stderr().writer(&.{});
        try printHelp(&err_writer2.interface);
        std.process.exit(2);
    }

    const code = switch (parsed.command) {
        .default_chat, .chat => try runChat(allocator, parsed),
        .ask => try runAsk(allocator, parsed),
        .find => try runFind(allocator, parsed),
        .help => 0,
    };
    std.process.exit(code);
}
