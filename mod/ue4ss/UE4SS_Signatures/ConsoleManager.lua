-- UE4SS's generic ConsoleManager scan finds four candidates in this game and aborts the whole scan.
-- UE4SS only requires this override to match (the address is not used), and this mod needs no console,
-- so it anchors on the StaticConstructObject_Internal prologue, which is unique in this build.
function Register()
    return "48 8B C4 48 89 58 10 48 89 70 18 48 89 78 20 55 41 54 41 55 41 56 41 57 48 8D A8 38 FE FF FF 48 81 EC A0 02 00 00 48 8B 05 ?? ?? ?? ?? 48 33 C4 48 89 85 90 01 00 00 4C 8B 31 33 DB 4C 8B 61 08"
end

function OnMatchFound(MatchAddress)
    return MatchAddress
end
