
meta =
{
    -- Unique id; keep this stable. A local mod keeps this id as-is.
    id = "copilot",

    -- Short internal name
    name = "Copilot",

    -- Title shown in the mod manager
    title = "Copilot (AI 副驾驶)",

    type = "mod",

    description = "An AI co-pilot that plays alongside you. In-sector it autopilots the ship you're flying; a strategic fleet/economy layer is in development (status: docs/dev/current-status.md).",

    authors = {"DSH"},

    version = "1.0.0",

    dependencies = {
        {id = "Avorion", min = "2.0.*", max = "2.5.*"}
    },

    -- Runs purely server-side (singleplayer runs its own server, so this is fine).
    serverSideOnly = false,
    clientSideOnly = false,
    saveGameAltering = false,

    contact = "",
}
