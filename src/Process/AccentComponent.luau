--!strict
local RunService = game:GetService("RunService")

local Root = script.Parent.Parent.Parent

local Config = require("../Config")
local Promise = require(Root.Promise)
local Signal = require(Root.Signal)

local CACHED_PART = Instance.new("Part")
CACHED_PART.Name = "AccentPart"
CACHED_PART.Size = Vector3.one * 1
CACHED_PART.CanCollide = false
CACHED_PART.Color = Color3.fromRGB(255, 0, 0)
CACHED_PART.CanQuery = false
CACHED_PART.Anchored = true
CACHED_PART.Transparency = 1

local COLLISION_GROUP = "PrimaryJunk"

local DEFAULT_COUNT = 1
local DEFAULT_TIMEOUT = 5
local DEFAULT_EMIT_COUNT = 1

local PART_CLASS_NAMES = {
	"Part",
	"Model",
	"MeshPart",
	"TrussPart",
	"CornerWedge",
}

local GET_ID: () -> number
local GET_SPAWN_ID: () -> number

do
	local lastId = 0
	local lastSpawnId = 0

	GET_ID = function()
		lastId += 1
		return lastId
	end

	GET_SPAWN_ID = function()
		lastSpawnId += 1
		return lastSpawnId
	end
end

local function isBasePartOrModelClass(Part: Instance): boolean
	for _, ClassName in PART_CLASS_NAMES do
		if ClassName == Part.ClassName then
			return true
		end
	end

	return false
end

local AccentComponent = {}
AccentComponent.__index = AccentComponent

local Builder = {}
Builder.__index = Builder

type Handler<T, P> = (T, P) -> ...any?

type LifecycleSignal = Signal.Signal<Instance>

export type BuilderConfig<T, P> = {
	Handler: Handler<T, P>,
	Props: T,
	Connection: Signal.Connection?,
}

export type AccentComponent = typeof(setmetatable(
	{} :: {
		Id: number,
		Instance: Instance,
		AccentPart: BasePart?,
		ClassName: string,
		ParentTo: Instance,
		Logging: boolean,

		OnSpawned: LifecycleSignal,
		OnDespawned: LifecycleSignal,
		OnTouched: LifecycleSignal,

		_activeClones: { [Instance]: number },
		_spawns: { [number]: { Container: Part?, Remaining: number } },
		_actions: { [Handler<any, any>]: BuilderConfig<any, any> },
		_reactions: { [LifecycleSignal]: { BuilderConfig<any, any> } },
		_alive: boolean,
	},
	AccentComponent
))

export type Builder<P> = {
	new: (self: Builder<P>) -> Builder<P>,
	Hook: (self: Builder<P>, Sig: LifecycleSignal) -> Builder<P>,
	Props: (self: Builder<P>, Props: P?) -> AccentComponent,

	Config: any,
	Accent: any,
}

--[[
	Could potentially be updated to be based on clone count rather than component count
]]
local ACTIVE_COMPONENTS: { [number]: AccentComponent } = {}
local CONNECTION: RBXScriptConnection?

local function startScheduler()
	if CONNECTION then
		return
	end

	CONNECTION = RunService.Heartbeat:Connect(function()
		local Now = os.clock()

		for _, Component in ACTIVE_COMPONENTS do
			if Component._alive then
				(Component :: any):Update(Now)
			end
		end
	end)
end

local function stopScheduler()
	if next(ACTIVE_COMPONENTS) ~= nil then
		return
	end

	if CONNECTION then
		CONNECTION:Disconnect()
		CONNECTION = nil
	end
end

function Builder.new<T, P>(Config: BuilderConfig<T, P>, Accent: AccentComponent): Builder<P>
	return setmetatable({
		Config = Config,
		Accent = Accent,
	}, Builder) :: any
end

function Builder.Hook<P>(self: Builder<P>, Sig: LifecycleSignal): Builder<P>
	local Accent = self.Accent

	Accent._reactions[Sig] = Accent._reactions[Sig] or {}
	table.insert(Accent._reactions[Sig], self.Config)

	return self
end

function Builder.Props<P>(self: Builder<P>, Props: P): AccentComponent
	self.Config.Props = Props
	return self.Accent
end

function AccentComponent.new(Target: Instance, Settings: any?): AccentComponent
	local MergedSettings = {}

	for k, v in Config.Settings :: any do
		MergedSettings[k] = Settings and Settings[k] or v
	end

	local self = setmetatable({
		Id = GET_ID(),
		Instance = Target:Clone(),
		ClassName = Target.ClassName,
		Settings = MergedSettings,
		Logging = MergedSettings.Logging or false,

		ParentTo = workspace :: Instance,

		OnSpawned = Signal.new(),
		OnDespawned = Signal.new(),
		OnTouched = Signal.new(),

		_activeClones = {},
		_spawns = {},
		_actions = {},
		_reactions = {},
		_alive = true,
	}, AccentComponent)

	ACTIVE_COMPONENTS[self.Id] = self
	startScheduler()

	return self
end

function AccentComponent.AddAction<T, P>(self: AccentComponent, Handler: Handler<T, P>): Builder<P>
	local ConfigData = {
		Handler = Handler,
		Connection = nil,
		Props = nil :: any,
	} :: any

	self._actions[Handler] = ConfigData

	return Builder.new(ConfigData, self)
end

function AccentComponent.AddReaction<T, P>(self: AccentComponent, Handler: Handler<T, P>): Builder<P>
	local ConfigData = {
		Handler = Handler,
		Connection = nil,
		Props = nil :: any,
	} :: any

	return Builder.new(ConfigData, self)
end

function AccentComponent.Spawn(self: AccentComponent, Position: Vector3, parent: Instance?): Promise.Promise
	if not self._alive then
		return Promise.reject("Accent destroyed")
	end

	local SpawnId = GET_SPAWN_ID()

	local IsPartOrModel = isBasePartOrModelClass(self.Instance)
	local Container: Part? = nil

	if not IsPartOrModel then
		Container = self:_createPart(Position)
	end

	self._spawns[SpawnId] = {
		Container = Container,
		Remaining = 0,
	}

	return Promise.try(function()
		self.ParentTo = parent or self.ParentTo

		local Count = self:_runAction(Config.Actions.Count)
			or self:_runAction(Config.Actions.RandomCount)
			or DEFAULT_COUNT

		local Lifetime = self:_runAction(Config.Actions.Lifetime)
			or self:_runAction(Config.Actions.RandomLifetime)
			or DEFAULT_TIMEOUT

		local EmitCount = self:_runAction(Config.Actions.EmitCount)
			or self:_runAction(Config.Actions.RandomEmitCount)
			or DEFAULT_EMIT_COUNT

		local IsParticleEmitter = self.Instance:IsA("ParticleEmitter")
		local IsSound = self.Instance:IsA("Sound")

		if IsParticleEmitter or IsSound then
			Count = 1
		end

		for _ = 1, Count do
			local Clone = self:_clone(Position)
			Clone:SetAttribute("__repertoire__spawnId", SpawnId)
			Clone.Parent = Container or self.ParentTo

			self._spawns[SpawnId].Remaining += 1

			if IsParticleEmitter then
				(Clone :: ParticleEmitter):Emit(EmitCount)
			elseif IsSound then
				(Clone :: Sound):Play()
			end

			local Expire = os.clock() + Lifetime
			self._activeClones[Clone] = Expire

			self:_executeReactions(self.OnSpawned, Clone)
				:andThen(function()
					self.OnSpawned:Fire(Clone)
				end)
				:catch(warn)
		end
	end)
end

function AccentComponent.Despawn(self: AccentComponent, Target: Instance): Promise.Promise?
	if not self._activeClones[Target] then
		return nil
	end

	self._activeClones[Target] = nil

	self.OnDespawned:Fire(Target)

	return self:_executeReactions(self.OnDespawned, Target):timeout(DEFAULT_TIMEOUT):finally(function()
		if Target then
			Target:Destroy()
		end

		local SpawnId = Target:GetAttribute("__repertoire__spawnId") :: number?
		if not SpawnId then
			return
		end

		local Spawn = self._spawns[SpawnId]
		if not Spawn then
			return
		end

		Spawn.Remaining -= 1

		if Spawn.Remaining <= 0 then
			if Spawn.Container then
				Spawn.Container:Destroy()
			end

			self._spawns[SpawnId] = nil
		end
	end)
end

function AccentComponent.Update(self: AccentComponent, Now: number)
	for Clone, Expire in self._activeClones do
		if Now >= Expire then
			self:Despawn(Clone)
		end
	end
end

function AccentComponent.Destroy(self: AccentComponent)
	if not self._alive then
		return
	end

	self._alive = false

	for Clone in self._activeClones do
		if not Clone then
			continue
		end
		Clone:Destroy()
	end

	for _, Spawn in self._spawns do
		if Spawn.Container then
			Spawn.Container:Destroy()
		end
	end

	ACTIVE_COMPONENTS[self.Id] = nil

	self.OnDespawned:Destroy()
	self.OnSpawned:Destroy()
	self.OnTouched:Destroy()

	stopScheduler()

	table.clear(self :: any)
	setmetatable(self :: any, nil)
end

function AccentComponent._executeReactions(
	self: AccentComponent,
	Sig: Signal.Signal<any>,
	Target: Instance
): Promise.Promise
	local Reactions = self._reactions[Sig]

	if not Reactions then
		return Promise.resolve()
	end

	if self.Logging then
		print("[Accent] Executing reactions:", #Reactions)
	end

	local Promises = table.create(#Reactions) :: { Promise.Promise }

	for _, Reaction in Reactions do
		table.insert(Promises :: any, Promise.try(Reaction.Handler, Target, Reaction.Props))
	end

	return Promise.all(Promises):andThen(function()
		if self.Logging then
			print("[Accent] All reactions finished:", Target)
		end
	end)
end

function AccentComponent._runAction(self: AccentComponent, Handler: Handler<any, any>): ...any?
	local Data = self._actions[Handler]

	if not Data then
		return nil
	end

	return Handler(nil :: any, Data.Props)
end

function AccentComponent._runByName(self: AccentComponent, Name: string, ...: any): any?
	for ActionName, Handler in Config.Actions :: any do
		if Name ~= ActionName then
			continue
		end

		for _, BuilderConfig in self._actions do
			if BuilderConfig.Handler ~= Handler then
				continue
			end

			return BuilderConfig.Handler(..., BuilderConfig.Props)
		end
	end

	return nil
end

function AccentComponent._clone(self: AccentComponent, Position: Vector3): (Instance, BasePart?)
	local Clone = self.Instance:Clone()
	local Primary: BasePart?

	if Clone:IsA("BasePart") then
		Primary = Clone
		Clone.Position = Position
	elseif Clone:IsA("Model") then
		Primary = Clone.PrimaryPart
		Clone:PivotTo(CFrame.new(Position))
	end

	if Primary then
		Primary.CollisionGroup = COLLISION_GROUP
	end

	return Clone, Primary
end

function AccentComponent._createPart(self: AccentComponent, Position: Vector3): Part
	local Clone = CACHED_PART:Clone()

	self:_runByName("AddCenterAttachment", Clone)
	self:_runByName("MutateSpawnPart", Clone)

	Clone.Position = Position
	Clone.Parent = self.ParentTo

	return Clone
end

return {
	new = AccentComponent.new,
}
