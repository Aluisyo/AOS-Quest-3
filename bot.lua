-- Constants
local BASE_ENERGY_THRESHOLD = 5
local BASE_ATTACK_RANGE = 1
local MOVE_ENERGY_THRESHOLD = 0

-- Initializing global variables to store the latest game state and game host process.
LatestGameState = LatestGameState or nil
InAction = InAction or false

Logs = Logs or {}
OpponentPositions = OpponentPositions or {}

colors = {
    red = "\27[31m",
    green = "\27[32m",
    blue = "\27[34m",
    reset = "\27[0m",
    gray = "\27[90m"
}

-- Utility Functions
local function addLog(msg, text)
    Logs[msg] = Logs[msg] or {}
    table.insert(Logs[msg], os.date("%X") .. ": " .. text)
end

local function inRange(x1, y1, x2, y2, range)
    return math.abs(x1 - x2) <= range and math.abs(y1 - y2) <= range
end

-- Attack Functions
local function getLowestEnergyPlayerInRange(x, y, range)
    local minEnergy = math.huge
    local targetInRange = nil

    for target, state in pairs(LatestGameState.Players) do
        if target ~= ao.id and inRange(x, y, state.x, state.y, range) and state.energy < minEnergy then
            minEnergy = state.energy
            targetInRange = target
        end
    end

    return targetInRange
end

local function attackLowestEnergyPlayer()
    local player = LatestGameState.Players[ao.id]
    local target = getLowestEnergyPlayerInRange(player.x, player.y, BASE_ATTACK_RANGE)

    while player.energy > BASE_ENERGY_THRESHOLD and target do
        print(colors.red .. "Player in range. Attacking." .. colors.reset)
        ao.send({Target = Game, Action = "PlayerAttack", Player = ao.id, AttackEnergy = tostring(player.energy)})
        target = getLowestEnergyPlayerInRange(player.x, player.y, BASE_ATTACK_RANGE)
    end
end

-- Rest Function
local function restAndRegainEnergy()
    local player = LatestGameState.Players[ao.id]
    if player and player.energy < BASE_ENERGY_THRESHOLD then
        print(colors.red .. "Energy is low. Resting to regain energy." .. colors.reset)
        ao.send({Target = Game, Action = "PlayerRest", Player = ao.id})
        InAction = false
    end
end

-- Strategic Movement Function
local function moveToTarget(x, y)
    local direction = getDirectionToTarget(x, y)
    ao.send({Target = Game, Action = "PlayerMove", Player = ao.id, Direction = direction})
end

-- Advanced Action Decision Function
local function decideNextAction()
    local player = LatestGameState.Players[ao.id]
    local targetInRange = getLowestEnergyPlayerInRange(player.x, player.y, BASE_ATTACK_RANGE)

    if player.energy > BASE_ENERGY_THRESHOLD and targetInRange then
        attackLowestEnergyPlayer()
    elseif player.energy <= MOVE_ENERGY_THRESHOLD then
        print(colors.red .. "Energy too low. Resting to regain energy." .. colors.reset)
        restAndRegainEnergy()
    else
        local energySource = findNearestEnergySource(player.x, player.y)
        local weakerPlayer = getLowestEnergyPlayerInRange(player.x, player.y, 5)

        if weakerPlayer then
            print(colors.red .. "Moving towards weaker player." .. colors.reset)
            moveToTarget(LatestGameState.Players[weakerPlayer].x, LatestGameState.Players[weakerPlayer].y)
        elseif energySource then
            print(colors.red .. "Moving towards energy source." .. colors.reset)
            moveToTarget(energySource.x, energySource.y)
        else
            print(colors.red .. "No targets available. Moving randomly." .. colors.reset)
            moveToTarget(math.random(1, 10), math.random(1, 10))
        end
    end
    InAction = false
end

-- Event Handlers
Handlers.add(
    "PrintAnnouncements",
    Handlers.utils.hasMatchingTag("Action", "Announcement"),
    function (msg)
        if msg.Event == "Started-Waiting-Period" then
            ao.send({Target = ao.id, Action = "AutoPay"})
        elseif (msg.Event == "Tick" or msg.Event == "Started-Game") and not InAction then
            InAction = true
            ao.send({Target = Game, Action = "GetGameState"})
        elseif InAction then
            print("Previous action still in progress. Skipping.")
        end
        print(colors.green .. msg.Event .. ": " .. msg.Data .. colors.reset)
    end
)

Handlers.add(
    "GetGameStateOnTick",
    Handlers.utils.hasMatchingTag("Action", "Tick"),
    function ()
        if not InAction then
            InAction = true
            print(colors.gray .. "Getting game state..." .. colors.reset)
            ao.send({Target = Game, Action = "GetGameState"})
        else
            print("Previous action still in progress. Skipping.")
        end
    end
)

Handlers.add(
    "AutoPay",
    Handlers.utils.hasMatchingTag("Action", "AutoPay"),
    function (msg)
        print("Auto-paying confirmation fees.")
        ao.send({Target = Game, Action = "Transfer", Recipient = Game, Quantity = "1000"})
    end
)

Handlers.add(
    "UpdateGameState",
    Handlers.utils.hasMatchingTag("Action", "GameState"),
    function (msg)
        local json = require("json")
        LatestGameState = json.decode(msg.Data)
        for playerID, state in pairs(LatestGameState.Players) do
            OpponentPositions[playerID] = {x = state.x, y = state.y}
        end
        ao.send({Target = ao.id, Action = "UpdatedGameState"})
        print("Game state updated. Print 'LatestGameState' for detailed view.")
    end
)

Handlers.add(
    "DecideNextAction",
    Handlers.utils.hasMatchingTag("Action", "UpdatedGameState"),
    function ()
        if LatestGameState.GameMode ~= "Playing" then
            InAction = false
            return
        end
        print("Deciding next action.")
        decideNextAction()
        ao.send({Target = ao.id, Action = "Tick"})
    end
)

Handlers.add(
    "ReturnAttack",
    Handlers.utils.hasMatchingTag("Action", "Hit"),
    function (msg)
        if not InAction then
            InAction = true
            local playerEnergy = LatestGameState.Players[ao.id].energy
            local attackerInRange = inRange(LatestGameState.Players[ao.id].x, LatestGameState.Players[ao.id].y, LatestGameState.Players[msg.Attacker].x, LatestGameState.Players[msg.Attacker].y, BASE_ATTACK_RANGE)
            if playerEnergy == nil then
                print(colors.red .. "Unable to read energy." .. colors.reset)
                ao.send({Target = Game, Action = "Attack-Failed", Reason = "Unable to read energy."})
            elseif playerEnergy == 0 or not attackerInRange then
                print(colors.red .. "Player has insufficient energy or attacker is out of range." .. colors.reset)
                ao.send({Target = Game, Action = "Attack-Failed", Reason = "Player has no energy or attacker is out of range."})
            else
                print(colors.red .. "Returning attack." .. colors.reset)
                ao.send({Target = Game, Action = "PlayerAttack", Player = ao.id, AttackEnergy = tostring(playerEnergy)})
            end
            InAction = false
            ao.send({Target = ao.id, Action = "Tick"})
        else
            print("Previous action still in progress. Skipping.")
        end
    end
)

-- Dynamic Threshold Adjustment
local function adjustThresholds()
    local playerCount = #LatestGameState.Players
    if playerCount <= 5 then
        BASE_ENERGY_THRESHOLD = 10
        BASE_ATTACK_RANGE = 2
    else
        BASE_ENERGY_THRESHOLD = 5
        BASE_ATTACK_RANGE = 1
    end
end

-- Pathfinding
local function findNearestEnergySource(x, y)
    local closestEnergySource = nil
    local closestDistance = math.huge

    for _, energySource in pairs(LatestGameState.EnergySources) do
        local distance = math.abs(x - energySource.x) + math.abs(y - energySource.y)
        if distance < closestDistance then
            closestEnergySource = energySource
            closestDistance = distance
        end
    end

    return closestEnergySource
end

-- Get Direction to Target
local function getDirectionToTarget(targetX, targetY)
    local player = LatestGameState.Players[ao.id]
    local xDiff = targetX - player.x
    local yDiff = targetY - player.y

    if math.abs(xDiff) > math.abs(yDiff) then
        return xDiff > 0 and "Right" or "Left"
    else
        return yDiff > 0 and "Down" or "Up"
    end
end

-- Main Loop
Handlers.add(
    "MainLoop",
    Handlers.utils.hasMatchingTag("Action", "Tick"),
    function ()
        if not InAction then
            InAction = true
            adjustThresholds()
            ao.send({Target = Game, Action = "GetGameState"})
        end
    end
)
