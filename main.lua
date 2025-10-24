
---@diagnostic disable: undefined-global
local LightModule = require("shader_light")


local shader_light = {}
local image = {}


function love.load()
    shader_light = LightModule.load()
    image = love.graphics.newImage("assets/pics/town.png")
end


function love.update(dt)
    if shader_light then
        LightModule.update(dt)
    end

    if love.mouse.isDown(2) then
        local mx, my = love.mouse.getPosition()
        StaticLights[1].position = {mx, my}
    end
end


function love.draw()
    love.graphics.setShader(shader_light)
        love.graphics.draw(image, 0, 0)
    love.graphics.setShader()

    love.graphics.print("Press Left Mouse Button to spawn light explosion", 10, 10)
    love.graphics.print("Press Right Mouse Button to move static light", 10, 30)
end

function love.keypressed(key)
    if key == "escape" then
        love.event.quit()
    end
end

function love.resize(w, h)
    LightModule.onResize(w, h)
end


function love.mousepressed(x, y, button, istouch, presses)
    if button == 1 then
        LightModule.spawnExplosion(x, y, 100.0, 0.5)
    end
end
