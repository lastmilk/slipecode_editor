---@meta
-- GENERATED FROM schema.json. Run tool/generate_schema.dart.

---@alias SlipeEventPhase 'will'|'did'
---@alias SlipeEventAction 'continue'|'modify'|'swallow'

---@class SlipeEvent
---@field type string
---@field phase SlipeEventPhase
---@field source string
---@field eventId string
---@field payload table

---@class SlipeEventDecision
---@field action SlipeEventAction
---@field event SlipeEvent?

---@class SlipeCommandOptions
---@field title string?
---@field category string?

---@class SlipeOverrideOptions
---@field priority integer?

slipe = { service = {}, events = {}, commands = {}, config = {}, keys = {}, json = {}, schema = {}, ui = {} }
pluginhook = {}

---@param options { capability: string, reason: string }
function pluginhook.init(options) end

---@class EditorOpenFileRequest
---@field path string

---@class EditorOpenFileResponse
---@field path string
---@field opened boolean

---@class EditorSaveFileRequest
---@field path string
---@field content string

---@class EditorSaveFileResponse
---@field path string
---@field saved boolean

---@class EditorApplyEditRequest
---@field path string
---@field content string

---@class EditorApplyEditResponse
---@field path string
---@field applied boolean

---@class CompletionListRequest
---@field language string
---@field text string
---@field cursor integer
---@field items table[]

---@class CompletionListResponse
---@field items table[]

---@class CommandExecuteRequest
---@field id string

---@alias CommandExecuteResponse any

---@class UiNotifyRequest
---@field message string
---@field level 'info'|'warning'|'error'?

---@class UiNotifyResponse
---@field shown boolean

---@overload fun(service: 'editor', operation: 'openFile', options: SlipeOverrideOptions?, handler: fun(request: EditorOpenFileRequest, next: fun(request: EditorOpenFileRequest): EditorOpenFileResponse): EditorOpenFileResponse)
---@overload fun(service: 'editor', operation: 'saveFile', options: SlipeOverrideOptions?, handler: fun(request: EditorSaveFileRequest, next: fun(request: EditorSaveFileRequest): EditorSaveFileResponse): EditorSaveFileResponse)
---@overload fun(service: 'editor', operation: 'applyEdit', options: SlipeOverrideOptions?, handler: fun(request: EditorApplyEditRequest, next: fun(request: EditorApplyEditRequest): EditorApplyEditResponse): EditorApplyEditResponse)
---@overload fun(service: 'completion', operation: 'list', options: SlipeOverrideOptions?, handler: fun(request: CompletionListRequest, next: fun(request: CompletionListRequest): CompletionListResponse): CompletionListResponse)
---@overload fun(service: 'command', operation: 'execute', options: SlipeOverrideOptions?, handler: fun(request: CommandExecuteRequest, next: fun(request: CommandExecuteRequest): CommandExecuteResponse): CommandExecuteResponse)
---@overload fun(service: 'ui', operation: 'notify', options: SlipeOverrideOptions?, handler: fun(request: UiNotifyRequest, next: fun(request: UiNotifyRequest): UiNotifyResponse): UiNotifyResponse)
function slipe.service.override(service, operation, options, handler) end

---@param eventType string
---@param options { phase: SlipeEventPhase?, priority: integer? }?
---@param handler fun(event: SlipeEvent): SlipeEventDecision?
function slipe.events.on(eventType, options, handler) end

---@param id string
function slipe.events.off(id) end

---@param command string
---@param options SlipeCommandOptions?
---@param handler fun(payload: table): any
function slipe.commands.register(command, options, handler) end

---@param command string
function slipe.commands.unregister(command) end

---@param message string
---@param level 'info'|'warning'|'error'?
---@return UiNotifyResponse
function slipe.ui.notify(message, level) end

---@param key string
---@param value any
function slipe.config.set(key, value) end

---@param activator string
---@param command string
function slipe.keys.bind(activator, command) end

---@param activator string
function slipe.keys.unbind(activator) end

---@param value any
---@return string
function slipe.json.encode(value) end

---@param value string
---@return any
function slipe.json.decode(value) end

---@param schema table
function slipe.schema.load(schema) end

---@param value any
---@param schema table?
---@return boolean? ok, string? error
function slipe.schema.validate(value, schema) end
