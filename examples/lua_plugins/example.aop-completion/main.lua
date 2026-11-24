pluginhook.init({
  capability = "editor.modify",
  reason = "为补全列表追加一个带 Lua 标识的候选项"
})

slipe.service.override("completion", "list", { priority = 20 }, function(request, next)
  local response = next(request)
  table.insert(response.items, {
    label = "Lua AOP Example",
    insertText = "lua_aop_example",
    kindLabel = "Lua",
    detail = "由 example.aop-completion 追加",
    kind = "snippet"
  })
  return response
end)
