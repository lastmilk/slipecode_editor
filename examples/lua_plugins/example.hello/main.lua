slipe.commands.register("example.hello", {
  title = "Lua Hello",
  category = "Lua 示例"
}, function()
  slipe.ui.notify("你好，来自 example.hello！", "info")
end)

slipe.keys.bind("ctrl+alt+l", "example.hello")
