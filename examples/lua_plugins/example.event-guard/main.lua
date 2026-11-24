pluginhook.init({
  capability = "editor.modify",
  reason = "在指定测试按键和 .lua-guard 文件上演示事件修改与吞掉"
})

slipe.events.on("editor.key", { phase = "will" }, function(event)
  local key = event.payload
  if key.action == "down" and key.key == "f9" and key.control and key.alt then
    return { action = "swallow" }
  end
  return { action = "continue" }
end)

slipe.events.on("file.willSave", { phase = "will" }, function(event)
  local path = event.payload.path or ""
  if not string.match(path, "%.lua%-guard$") then
    return { action = "continue" }
  end

  local content = event.payload.content or ""
  if string.find(content, "SLIPE_BLOCK_SAVE", 1, true) then
    return { action = "swallow" }
  end

  event.payload.content = "-- Lua event guard: reviewed\n" .. content
  return { action = "modify", event = event }
end)
