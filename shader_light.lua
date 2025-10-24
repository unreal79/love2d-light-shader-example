-- Shader code and light management module
local ShaderLightModule = {}

local SHADER_LIGHT_CODE = [[
#define MAX_LIGHTS 64

struct Light {
    vec2 position;
    vec3 diffuse;
    float power;
};

extern vec2 screen_size;

extern Light lights[MAX_LIGHTS];
extern int num_lights;

extern float constant = 1.0;
extern float linear = 0.09;
extern float quadratic = 0.032;

vec4 effect(vec4 color, Image image, vec2 uvs, vec2 screen_coords){
    vec4 pixel = Texel(image, uvs);

    vec2 norm_screen = screen_coords / screen_size;
    // Correct for aspect ratio so light falloff is circular on non-square screens
    float aspect = screen_size.x / screen_size.y;
    vec3 diffuse = vec3(0);

    for (int i = 0; i < num_lights; i++) {
        Light light = lights[i];
        vec2 norm_pos = light.position / screen_size;
        vec2 diff = norm_pos - norm_screen;
        // Scale X by aspect before distance to keep isotropic falloff
        diff.x *= aspect;
        float distance = length(diff) * light.power;
        diffuse += light.diffuse / (constant + linear * distance + quadratic * (distance * distance));
    }

    diffuse = clamp(diffuse, 0.0, 1.0);

    return pixel * vec4(diffuse, 1.0);
}
]]


local MAX_LIGHTS = 64

local light_shader = {}
StaticLights = {}
Explosions = {}
TorchLights = {}


-- Converts user-facing power (0..100; higher = brighter)
-- to the shader attenuation multiplier.
---- Guarantees: 0 -> 10000, 70 -> ~30, 100 -> ~0 (clamped to 0)
local function LightToShaderPower(userPower)
    if userPower < 1.0 then return 10000.0 end
    if userPower > 99.9 then return 0.0 end
    local beta = 0.083 -- ensures ~30 at userPower=70
    local value = 10000.0 * math.exp(-beta * userPower)
    return value
end


-- Updates the screen_size uniform when the window is resized.
function ShaderLightModule.onResize(w, h)
    if light_shader then
        light_shader:send("screen_size", {w, h})
    end
end


-- Loads and initializes the light shader, sets the screen size,
-- and adds default static lights.
---- Returns the shader object.
function ShaderLightModule.load()
    light_shader = love.graphics.newShader(SHADER_LIGHT_CODE)
    if light_shader == nil then
        error("Failed to load light shader")
        return nil
    end
    light_shader:send("screen_size", {love.graphics.getWidth(), love.graphics.getHeight()})

    -- Seed default static lights via AddStaticLights
    ShaderLightModule.AddStaticLights(
        love.graphics.getWidth() / 3, love.graphics.getHeight() / 3,
        60.0,
        {1.0, 1.0, 1.0}
    )
    ShaderLightModule.AddStaticLights(
        love.graphics.getWidth() * 0.85, love.graphics.getHeight() * 0.75,
        70.0,
        {1.0, 0.3, 0.3}
    )
    ShaderLightModule.AddStaticLights(
        love.graphics.getWidth() / 2, love.graphics.getHeight() / 2,
        80.0,
        {0.0, 0.0, 1.0}
    )

    ShaderLightModule.spawnTorch(100, 500, 60, 5.0, {infinite = true, diffuse={1.0, 0.85, 0.5}})

    return light_shader
end


-- Adds a static light and returns its index (1..N).
---- Accepts parameters (x, y, power, [diffuse]).
---- Returns the index or nil if the limit is reached.
function ShaderLightModule.AddStaticLights(x, y, power, diffuse)
    if #StaticLights >= MAX_LIGHTS then return nil end

    local entry = {
        position = {x or 0, y or 0},
        diffuse = diffuse or {1.0, 1.0, 1.0},
        power = power or 0.0
    }

    table.insert(StaticLights, entry)
    return #StaticLights
end


-- Deletes a static light by index (1..N).
---- Returns true on success, false if index is invalid.
function ShaderLightModule.RemoveStaticLight(index)
    if not StaticLights[index] then return false end
    table.remove(StaticLights, index)
    return true
end

-- Deletes a torch light by index (1..N).
---- Returns true on success, false if index is invalid.
function ShaderLightModule.RemoveTorchLight(index)
    if not TorchLights[index] then return false end
    table.remove(TorchLights, index)
    return true
end


-- Replaces the entire static light array.
---- Expects an array of tables with fields position, power, diffuse.
function ShaderLightModule.SetStaticLights(lights)
    StaticLights = lights or StaticLights
end


-- Creates a short-lived light "explosion" at (x, y),
-- with peak intensity (0..100) and duration in seconds.
-- The flash starts instantly and decays smoothly (exponentially).
function ShaderLightModule.spawnExplosion(x, y, intensity, duration, diffuse)
    local inten = math.max(0, math.min(intensity or 100, 100)) / 100.0
    local dur = math.max(0.01, duration or 1.0)
    -- sanitize diffuse color (defaults to white)
    local diff = diffuse or {1.0, 1.0, 1.0}
    diff[1] = math.max(0.0, math.min(diff[1] or 1.0, 1.0))
    diff[2] = math.max(0.0, math.min(diff[2] or 1.0, 1.0))
    diff[3] = math.max(0.0, math.min(diff[3] or 1.0, 1.0))
    table.insert(Explosions, {
        x = x or love.graphics.getWidth() * 0.5,
        y = y or love.graphics.getHeight() * 0.5,
        intensity = inten,
        duration = dur,
        elapsed = 0.0,
        diffuse = diff
    })
end


-- Updates state (explosions) and sends all lights to the shader.
-- Helper that applies one explosion light to the shader at index `idx`.
---- Parameters:
----   e   - explosion state {x,y,intensity,duration,elapsed}
----   idx - current light index into lights[] uniform array
----   exp - exponential decay coefficient (defaults to -5)
----   powerBase - base power multiplier for explosion size (default 500)
---- Returns next idx (idx + 1).
function ShaderLightModule.funcExplosion(e, idx, exp, powerBase)
    if not light_shader then return idx end
    exp = (exp ~= nil) and exp or -5.0

    local t = math.max(0.0, math.min(e.elapsed / e.duration, 1.0))
    -- brightness decays exponentially with configurable coefficient
    local brightness = e.intensity * math.exp(exp * t)
    if brightness < 0.001 then brightness = 0.0 end

    local name = "lights[" .. idx .. "]"
    light_shader:send(name .. ".position", {e.x, e.y})
    -- Apply explosion's base color scaled by brightness
    local base = e.diffuse or {1.0, 1.0, 1.0}
    local col = { base[1] * brightness, base[2] * brightness, base[3] * brightness }
    light_shader:send(name .. ".diffuse", col)
    -- Start very bright reach and shrink over time
    local power = (powerBase or 500) * t
    light_shader:send(name .. ".power", power)

    return idx + 1
end


-- Torch light: subtle flicker using smooth randomness.
-- Behavior:
---- Uses love.math.noise for smooth pseudo-random variation over time (no abrupt jumps)
---- Has a duration, but after it ends the light remains frozen in its last state
---- If `t.infinite == true`, the torch flickers forever and never freezes (ignores duration)
---- Parameters (fields on `t` table):
----   t.x, t.y                 - position
----   t.basePower              - shader power computed from spawnTorch intensity (0..100 -> LightToShaderPower)
----   t.intensity (0..1)       - base color brightness factor for flicker (optional; default 1.0)
----   t.duration (seconds)     - duration of active flicker; if <= 0, infinite
----   t.elapsed                - updated externally in update(); used for noise time
----   t.seed                   - optional seed for unique noise track; auto-generated if absent
----   t.diffuse                - optional base color {r,g,b}; default warm torch color
----   t.speed                  - optional noise speed; default 2.0
----   t.amp                    - optional flicker amplitude [0..1]; default 0.35 (35%)
----   t.smooth                 - optional smoothing factor (0..1]; default 0.2
----   t.frozen                 - internal: if true, brightness/power stay constant
----   t.infinite               - if true, never freeze (ignores duration)
---- Returns next idx (idx + 1).
function ShaderLightModule.funcTorch(t, idx)
    if not light_shader then return idx end

    -- Freeze: if duration elapsed, keep last values
    local isInfinite = t.infinite == true
    if not isInfinite and t.duration and t.duration > 0 and t.elapsed and t.elapsed >= t.duration then
        t.frozen = true
    elseif isInfinite then
        t.frozen = false
    end

    local name = "lights[" .. idx .. "]"

    -- Initialize defaults
    local baseColor = t.diffuse or {1.0, 0.85, 0.5} -- warm torch
    local basePower = t.basePower or 60.0
    local speed = t.speed or 2.0
    local amp = math.max(0.0, math.min(t.amp or 0.35, 0.95))
    local smooth = math.max(0.01, math.min(t.smooth or 0.2, 1.0))
    local intensity = math.max(0.0, math.min(t.intensity or 1.0, 1.0))

    -- Unique noise seed per torch
    if not t.seed then t.seed = love.math.random() * 1000.0 end

    -- Compute target brightness using smooth noise (0..1)
    if not t.frozen then
        local time = (t.elapsed or 0.0) * speed
        local n = love.math.noise(t.seed, time) -- 0..1
        -- Map noise to [1-amp .. 1+amp] scale around 1.0, then scale by base intensity
        local flicker = 1.0 - amp + (2.0 * amp) * n
        local targetBrightness = intensity * flicker
        if t.lastBrightness == nil then
            t.lastBrightness = targetBrightness
        else
            -- Exponential smoothing to avoid abrupt changes
            t.lastBrightness = t.lastBrightness + (targetBrightness - t.lastBrightness) * smooth
        end

        -- Slight power jitter (±10%) tied to another noise channel
        local n2 = love.math.noise(t.seed + 123.456, time * 0.5)
        local powerJitter = 0.9 + 0.2 * n2
        t.lastPower = basePower * powerJitter
    end

    -- Freeze values if needed
    if t.frozen then
        t.lastBrightness = t.lastBrightness or (intensity * (1.0 - amp))
        t.lastPower = t.lastPower or basePower
    end

    -- Compose diffuse color scaled by brightness
    local b = math.max(0.0, math.min(t.lastBrightness or intensity, 1.0))
    local diffuse = { baseColor[1] * b, baseColor[2] * b, baseColor[3] * b }

    light_shader:send(name .. ".position", {t.x, t.y})
    light_shader:send(name .. ".diffuse", diffuse)
    light_shader:send(name .. ".power", t.lastPower or basePower)

    return idx + 1
end


-- Spawns a torch light entry and returns its index in TorchLights.
---- Parameters:
----   intensity (0..100) - perceived brightness mapped to shader power via LightToShaderPower
----   duration (seconds) - flicker time before freezing; ignored if opts.infinite == true
----   opts:
----     diffuse {r,g,b}  - base color (unchanged by intensity mapping)
----     infinite boolean - if true, torch flickers forever
----     brightness (0..1)- optional base color brightness used by flicker (default 1.0)
function ShaderLightModule.spawnTorch(x, y, intensity, duration, opts)
    local t = opts or {}
    t.x = x or love.graphics.getWidth() * 0.5
    t.y = y or love.graphics.getHeight() * 0.5
    local userInt = math.max(0.0, math.min(intensity or 100.0, 100.0))
    t.basePower = LightToShaderPower(userInt)
    -- Keep diffuse unchanged; brightness factor for color can be customized via opts.brightness
    t.intensity = math.max(0.0, math.min((t.brightness or t.intensity or 1.0), 1.0))
    t.duration = duration or 0 -- 0 or negative means infinite flicker
    t.elapsed = 0.0
    table.insert(TorchLights, t)
    return #TorchLights
end


-- Updates state (explosions) and sends all lights to the shader.
function ShaderLightModule.update(dt)
    local idx = 0

    -- Send static lights
    for _, light in ipairs(StaticLights) do
        local name = "lights[" .. idx .. "]"
        light_shader:send(name .. ".position",  light.position)
        light_shader:send(name .. ".diffuse", light.diffuse)
        light_shader:send(name .. ".power", LightToShaderPower(light.power))
        idx = idx + 1
    end

    -- Update explosions
    for i = #Explosions, 1, -1 do
        local e = Explosions[i]
        e.elapsed = e.elapsed + dt
        if e.elapsed >= e.duration then
            table.remove(Explosions, i)
        end
    end
    -- Send explosions
    local remaining = MAX_LIGHTS - idx
    if remaining > 0 then
        local count = math.min(#Explosions, remaining)
        for i = 1, count do
            local e = Explosions[i]
            idx = ShaderLightModule.funcExplosion(e, idx, -3, 700)
        end
    end

    -- Update torches
    for i = 1, #TorchLights do
        local t = TorchLights[i]
        t.elapsed = (t.elapsed or 0) + dt
        -- Freeze only if not infinite and duration is finite and elapsed exceeded duration
        if not t.infinite and (t.duration or 0) > 0 and not t.frozen and t.elapsed >= t.duration then
            t.frozen = true -- keep final state thereafter
        end
        -- If explicitly infinite, ensure not frozen
        if t.infinite then t.frozen = false end
    end
    -- Send torches
    remaining = MAX_LIGHTS - idx
    if remaining > 0 and #TorchLights > 0 then
        local count = math.min(#TorchLights, remaining)
        for i = 1, count do
            local t = TorchLights[i]
            idx = ShaderLightModule.funcTorch(t, idx)
        end
    end

    light_shader:send("num_lights", idx)
end


return ShaderLightModule
