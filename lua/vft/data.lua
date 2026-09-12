-- VF: static tables only. Split out for the 200-local cap.

local ALL_ABBR          = { 'War', 'Clr', 'Pal', 'Rng', 'SK', 'Dru', 'Mnk', 'Brd', 'Rog', 'Shm',
    'Nec', 'Wiz', 'Mag', 'Enc', 'Bst', 'Ber' }

local GOLD              = { 0.769, 0.627, 0.439, 1 }

local ARC               = { 0.710, 0.420, 1.000, 1 }

local MUTED             = { 0.541, 0.439, 0.533, 1 }

local GOOD              = { 0.37, 0.88, 0.64, 1 }

local WARN              = { 0.878, 0.659, 0.471, 1 }

local NUM_GEMS       = 12

local PRIMARY_MODES  = { 'Manual', 'Roam', 'Rush', 'Group' }

local SUBMODES       = {
}

local PULL_STYLES    = { 'Melee', 'Spell', 'Pet', 'Ranged' }

local PULL_CON_LIST  = {
    'Scowling',
    'Threateningly',
    'Dubious',
    'Apprehensive',
    'Indifferent',
    'Amiably',
    'Kindly',
    'Warmly',
    'Ally',
}

local MODE_DESC      = {
    Manual = 'You walk and press attack. TA plays the loadout until the pack is clear. Map travel is not a mode.',
    Roam = 'Roams within search radius (or walks a loop route) and kills on the spot.',
    Rush = 'Runs Combat locs. Ignores adds until arrival, then clears the pin. Next loc when the pin is cold.',
    Group = 'Follow the group anchor (/afollow). Fight when the anchor pulls. Set Main Assist or Main Tank in the group window.',
}

local SUBMODE_DESC   = {
}

local PET_CLASSES = { Nec = true, Mag = true, Bst = true, Enc = true, Shm = true, SK = true, Dru = true }

local FRIENDLY = { 'Myself', 'Main Assist', 'Tank', 'Lowest-HP Ally', 'Whole Group', 'Pet' }

local ENEMY    = { 'Current Target', 'Assist Target', 'Nearest Add', 'Unmezzed Add', 'All Enemies' }

local TARGETS  = {}
for _, t in ipairs(FRIENDLY) do TARGETS[#TARGETS + 1] = 'F: ' .. t end
for _, t in ipairs(ENEMY) do TARGETS[#TARGETS + 1] = 'E: ' .. t end

local WHENS = { 'HP <=', 'target HP <=', 'my HP <=', 'my Mana <=', 'missing buff', 'missing pet', 'has Poison/Disease',
    'ally is Dead', 'add is loose', 'twist while fighting', 'in combat',
    'always' }

local ALIAS_CLASS_MAP = {
    SK = 'SK',
    SHD = 'SK',
    BST = 'Bst',
    Bst = 'Bst',
    SHM = 'Shm',
    Shm = 'Shm',
}

local PURE_MELEE_CLASSES = { War = true, WAR = true, Mnk = true, MNK = true, Rog = true, ROG = true, Ber = true, BER = true }

return {
    ALL_ABBR = ALL_ABBR,
    GOLD = GOLD,
    ARC = ARC,
    MUTED = MUTED,
    GOOD = GOOD,
    WARN = WARN,
    NUM_GEMS = NUM_GEMS,
    PRIMARY_MODES = PRIMARY_MODES,
    MAIN_MODES = PRIMARY_MODES,
    SUBMODES = SUBMODES,
    PULL_STYLES = PULL_STYLES,
    PULL_CON_LIST = PULL_CON_LIST,
    MODE_DESC = MODE_DESC,
    SUBMODE_DESC = SUBMODE_DESC,
    PET_CLASSES = PET_CLASSES,
    FRIENDLY = FRIENDLY,
    ENEMY = ENEMY,
    TARGETS = TARGETS,
    WHENS = WHENS,
    ALIAS_CLASS_MAP = ALIAS_CLASS_MAP,
    PURE_MELEE_CLASSES = PURE_MELEE_CLASSES,
}
