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


-- Internal state
local light_shader = nil
local MAX_LIGHTS = 64
-- User-facing static lights (power in [0..100], higher = brighter)
StaticLights = {}
Explosions = {}




-- Converts user-facing power (0..100; higher = brighter)
-- to the shader attenuation multiplier.
-- Guarantees: 0 -> 10000, 70 -> ~30, 100 -> ~0 (clamped to 0)
local function LightToShaderPower(userPower)
    if userPower < 1.0 then return 10000.0 end
    if userPower > 99.9 then return 0.0 end
    local beta = 0.083 -- ensures ~30 at userPower=70
    local value = 10000.0 * math.exp(-beta * userPower)
    return value
end


-- Loads and initializes the light shader, sets the screen size,
-- and adds default static lights.
-- Returns the shader object.
function ShaderLightModule.Load()
    light_shader = love.graphics.newShader(SHADER_LIGHT_CODE)
    light_shader:send("screen_size", {love.graphics.getWidth(), love.graphics.getHeight()})

    -- Seed default static lights via AddStaticLights
    ShaderLightModule.AddStaticLights(
        love.graphics.getWidth() / 3, love.graphics.getHeight() / 3,
        {1.0, 1.0, 1.0},
        60.0
    )
    ShaderLightModule.AddStaticLights(
        love.graphics.getWidth() * 0.85, love.graphics.getHeight() * 0.75,
        {1.0, 0.3, 0.3},
        70.0
    )
    ShaderLightModule.AddStaticLights(
        love.graphics.getWidth() / 2, love.graphics.getHeight() / 2,
        {0.0, 0.0, 1.0},
        80.0
    )

    return light_shader
end


-- Adds a static light and returns its index (1..N).
-- Accepts parameters (x, y, [diffuse], power).
-- Returns the index or nil if the limit is reached.
function ShaderLightModule.AddStaticLights(x, y, diffuse, power)
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
-- Returns true on success, false if index is invalid.
function ShaderLightModule.DeleteStaticLight(index)
    if not StaticLights[index] then return false end
    table.remove(StaticLights, index)
    return true
end


-- Updates the screen_size uniform when the window is resized.
function ShaderLightModule.onResize(w, h)
    if light_shader then
        light_shader:send("screen_size", {w, h})
    end
end


-- Replaces the entire static light array.
-- Expects an array of tables with fields position, power, diffuse.
function ShaderLightModule.SetStaticLights(lights)
    StaticLights = lights or StaticLights
end


-- Creates a short-lived light "explosion" at (x, y),
-- with peak intensity (0..100) and duration in seconds.
-- The flash starts instantly and decays smoothly (exponentially).
function ShaderLightModule.spawnExplosion(x, y, intensity, duration)
    local inten = math.max(0, math.min(intensity or 100, 100)) / 100.0
    local dur = math.max(0.01, duration or 1.0)
    table.insert(Explosions, {
        x = x or love.graphics.getWidth() * 0.5,
        y = y or love.graphics.getHeight() * 0.5,
        intensity = inten,
        duration = dur,
        elapsed = 0.0
    })
end


-- Updates state (explosions) and sends all lights to the shader.
-- Call once per frame.
function ShaderLightModule.update(dt)
    if not light_shader then return end

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
            local t = math.max(0.0, math.min(e.elapsed / e.duration, 1.0))
            local brightness = e.intensity * math.exp(-5.0 * t)
            if brightness < 0.001 then brightness = 0.0 end

            local name = "lights[" .. idx .. "]"
            light_shader:send(name .. ".position", {e.x, e.y})
            light_shader:send(name .. ".diffuse", {brightness, brightness, brightness})
            -- Start very bright reach and shrink
            local power = 500 * t -- Adjusted from 200 to 1000
            light_shader:send(name .. ".power", power)
            idx = idx + 1
        end
    end

    light_shader:send("num_lights", idx)
end


return ShaderLightModule

