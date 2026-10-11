// GENERATED from design/audio_cues.json by tools/Sheets. Do not edit; change the sheet.
namespace SpideyLink;

public sealed record Cue(string Id, string Kind, string? Bank, string? Events, uint[] Streams, double CooldownS, double Chance, float Volume, double MaxClipS);

public static class Cues
{
    public static readonly Cue[] All =
    {
        new("music_traversal", "music", "sound\\banks\\i20_mus_ow_a1.soundbank", null, new uint[] { 32382339u, 592482711u }, 0.0, 1.0, 0.55f, 0.0),
        new("music_stop", "control", null, null, System.Array.Empty<uint>(), 0.0, 1.0, 0.0f, 0.0),
        new("vo_suit_up", "vo", "sound\\banks\\spid.soundbank", "SPID_GEN_LEVELSTART", System.Array.Empty<uint>(), 0.0, 1.0, 1.0f, 3.0),
        new("vo_swing", "vo", "sound\\banks\\spid.soundbank", "SPID_GEN_SMALL_SWING", System.Array.Empty<uint>(), 6.0, 0.35, 0.9f, 3.0),
        new("vo_big_swing", "vo", "sound\\banks\\spid.soundbank", "SPID_GEN_LARGE_SWING", System.Array.Empty<uint>(), 10.0, 0.6, 0.9f, 3.0),
        new("vo_fling", "vo", "sound\\banks\\spid.soundbank", "SPID_GEN_JUMP_LONG", System.Array.Empty<uint>(), 4.0, 0.4, 0.9f, 3.0),
        new("vo_zip", "vo", "sound\\banks\\spid.soundbank", "SPID_GEN_EXERT", System.Array.Empty<uint>(), 3.0, 0.5, 0.9f, 3.0),
        new("vo_land_hard", "vo", "sound\\banks\\spid.soundbank", "SPID_GEN_LAND_HARD", System.Array.Empty<uint>(), 5.0, 0.8, 0.9f, 3.0),
        new("vo_rooftop_quip", "vo", "sound\\banks\\spid.soundbank", "SPID_GEN_ROOFTOP", System.Array.Empty<uint>(), 25.0, 0.7, 1.0f, 3.0),
        new("sfx_web_shoot", "sfx", "sound\\banks\\wpn_webline.soundbank", "WEP_I20_WebLine_Thrown", System.Array.Empty<uint>(), 0.0, 1.0, 0.8f, 3.0),
        new("sfx_web_shot", "sfx", "sound\\banks\\i20_hero_weapons.soundbank", "Play_Hero_WebShoot", System.Array.Empty<uint>(), 0.0, 1.0, 0.85f, 3.0),
        new("sfx_web_hit", "sfx", "sound\\banks\\i20_hero_weapons.soundbank", "Play_WPN_Web_Impact_Hit", System.Array.Empty<uint>(), 0.0, 1.0, 0.9f, 3.0),
        new("sfx_web_splat", "sfx", "sound\\banks\\i20_hero_weapons.soundbank", "WPN_Web_Impact_Splat_Generic_Louder", System.Array.Empty<uint>(), 0.0, 1.0, 0.7f, 3.0),
    };
}
