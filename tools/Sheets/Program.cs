// Design sheets -> preflight + generated code.
// usage: dotnet run --project tools/Sheets -- preflight|generate <repo root>
// Every row becomes one generated table/record; every cell must be filled ("n/a" when it does not apply).
using System.Globalization;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;

var cmd = args.Length > 0 ? args[0] : "preflight";
var root = args.Length > 1 ? args[1] : Directory.GetCurrentDirectory();
var sheets = new Dictionary<string, JsonObject>();
foreach (var f in Directory.GetFiles(Path.Combine(root, "design"), "*.json").OrderBy(x => x))
{
    var s = JsonNode.Parse(File.ReadAllText(f))!.AsObject();
    sheets[s["sheet"]!.GetValue<string>()] = s;
}

IEnumerable<JsonObject> Rows(string n) => sheets[n]["rows"]!.AsArray().Select(r => r!.AsObject());
List<string> Cols(string n) => sheets[n]["columns"]!.AsArray().Select(c => c!.GetValue<string>()).ToList();
Dictionary<string, JsonObject> ById(string n) => Rows(n).ToDictionary(r => S(r["id"]));
static string S(JsonNode? n) => n is JsonValue v && v.TryGetValue<string>(out var s) ? s : n?.ToJsonString() ?? "";
static bool NA(JsonNode? n) => S(n) == "n/a";

var problems = new List<string>();
foreach (var (name, s) in sheets)
{
    var cols = Cols(name);
    foreach (var r in Rows(name))
    {
        foreach (var c in cols)
        {
            var v = r[c];
            var str = S(v);
            if (v == null || str == "" || (v is JsonArray a && a.Count == 0)) problems.Add($"{name}.{S(r["id"])}.{c}: empty");
            else if (str.StartsWith("unverified", StringComparison.OrdinalIgnoreCase)) problems.Add($"{name}.{S(r["id"])}.{c}: unverified");
            else if (str.StartsWith("partial", StringComparison.OrdinalIgnoreCase)) problems.Add($"{name}.{S(r["id"])}.{c}: partially verified ({str})");
        }
        foreach (var k in r.Select(p => p.Key)) if (!cols.Contains(k)) problems.Add($"{name}.{S(r["id"])}: unknown column {k}");
    }
}
var ab = ById("abilities"); var inp = ById("inputs"); var cues = ById("audio_cues");
foreach (var a in ab.Values)
{
    if (!inp.ContainsKey(S(a["input"]))) problems.Add($"abilities.{S(a["id"])}.input -> inputs.{S(a["input"])} missing");
    foreach (var c in new[] { "cue_on_start", "cue_on_end" })
        if (!NA(a[c]) && !cues.ContainsKey(S(a[c]))) problems.Add($"abilities.{S(a["id"])}.{c} -> audio_cues.{S(a[c])} missing");
}
foreach (var i in inp.Values)
    foreach (var u in S(i["used_by"]).Split(','))
        if (!ab.ContainsKey(u)) problems.Add($"inputs.{S(i["id"])}.used_by -> abilities.{u} missing");
foreach (var c in cues.Values)
{
    var kind = S(c["kind"]);
    if ((kind == "vo" || kind == "sfx") && (NA(c["events"]) || NA(c["bank"]))) problems.Add($"audio_cues.{S(c["id"])}: vo/sfx needs bank+events");
    if (kind == "music" && c["streams"] is not JsonArray) problems.Add($"audio_cues.{S(c["id"])}: music needs streams");
}
foreach (var s in Rows("suit"))
{
    var kind = S(s["kind"]);
    if (kind == "texture" && !S(s["value"]).StartsWith("game:") && !File.Exists(Path.Combine(root, "mod", "ue4ss", "Mods", "SpideyGotham", S(s["value"]).Replace('/', Path.DirectorySeparatorChar))))
        problems.Add($"suit.{S(s["id"])}.value -> {S(s["value"])} not built (run tools/make_spidey_prints.py)");
}
foreach (var h in Rows("game_hooks"))
    foreach (var u in S(h["used_by"]).Split(','))
        if (!ab.ContainsKey(u) && u != "all" && u != "inputs") problems.Add($"game_hooks.{S(h["id"])}.used_by -> {u} missing");

foreach (var p in problems) Console.WriteLine("PREFLIGHT: " + p);
Console.WriteLine($"{problems.Count} open cells/references");
if (cmd != "generate") return problems.Count == 0 ? 0 : 1;

string Lua(JsonNode? v)
{
    if (v is JsonArray arr) return "{" + string.Join(", ", arr.Select(Lua)) + "}";
    if (v is JsonValue jv)
    {
        if (jv.TryGetValue<bool>(out var b)) return b ? "true" : "false";
        if (jv.TryGetValue<double>(out var d)) return d.ToString(CultureInfo.InvariantCulture);
        var s = jv.GetValue<string>();
        return s == "n/a" ? "nil" : LuaStr(s);
    }
    return "nil";
}
static string LuaStr(string s) => "\"" + s.Replace("\\", "\\\\").Replace("\"", "\\\"").Replace("\n", "\\n") + "\"";
var lua = new StringBuilder("-- GENERATED from design/*.json by tools/Sheets. Do not edit; change the sheets.\nlocal C = {}\n");
foreach (var name in new[] { "abilities", "inputs", "suit", "ability_blocks" })
{
    lua.Append($"C.{name} = {{}}\n");
    foreach (var r in Rows(name))
        lua.Append($"C.{name}.{S(r["id"])} = {{ {string.Join(", ", Cols(name).Select(c => $"{c} = {Lua(r[c])}"))} }}\n");
}
lua.Append("C.cues = {}\n");
foreach (var r in Rows("audio_cues")) lua.Append($"C.cues.{S(r["id"])} = \"{S(r["id"])}\"\n");
lua.Append("return C\n");
var luaPath = Path.Combine(root, "mod", "ue4ss", "Mods", "SpideyGotham", "Scripts", "config.lua");
Directory.CreateDirectory(Path.GetDirectoryName(luaPath)!);
File.WriteAllText(luaPath, lua.ToString());

string F(JsonNode? n) => double.Parse(S(n), CultureInfo.InvariantCulture).ToString("0.0###", CultureInfo.InvariantCulture);
var cs = new StringBuilder("// GENERATED from design/audio_cues.json by tools/Sheets. Do not edit; change the sheet.\nnamespace SpideyLink;\n\n");
cs.Append("public sealed record Cue(string Id, string Kind, string? Bank, string? Events, uint[] Streams, double CooldownS, double Chance, float Volume, double MaxClipS);\n\n");
cs.Append("public static class Cues\n{\n    public static readonly Cue[] All =\n    {\n");
foreach (var r in Rows("audio_cues"))
{
    string bank = NA(r["bank"]) ? "null" : JsonSerializer.Serialize(S(r["bank"]));
    string ev = NA(r["events"]) ? "null" : JsonSerializer.Serialize(S(r["events"]));
    string st = r["streams"] is JsonArray sa ? "new uint[] { " + string.Join(", ", sa.Select(x => x!.ToJsonString() + "u")) + " }" : "System.Array.Empty<uint>()";
    cs.Append($"        new(\"{S(r["id"])}\", \"{S(r["kind"])}\", {bank}, {ev}, {st}, {F(r["cooldown_s"])}, {F(r["chance"])}, {F(r["volume"])}f, {(NA(r["max_clip_s"]) ? "0.0" : F(r["max_clip_s"]))}),\n");
}
cs.Append("    };\n}\n");
File.WriteAllText(Path.Combine(root, "src", "SpideyLink", "Generated.cs"), cs.ToString());
Console.WriteLine("generated config.lua and Generated.cs");
return 0;
