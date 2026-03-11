--!nonstrict
local SequenceComponent = require("@self/SequenceComponent")

export type SequenceComponent = SequenceComponent.SequenceComponent

local SceneComponent = {}
SceneComponent.__index = SceneComponent

export type SceneComponent = typeof(setmetatable(
	{} :: {
		SequenceComponents: { SequenceComponent },
	},
	SceneComponent
))

function SceneComponent.new(): SceneComponent
	return setmetatable({
		SequenceComponents = {},
	}, SceneComponent)
end

function SceneComponent.Sequence(self: SceneComponent, Process: (self: SequenceComponent) -> ()): SequenceComponent
	local Sequence = SequenceComponent.new(self, Process)
	table.insert(self.SequenceComponents, Sequence)
	return Sequence
end

function SceneComponent.Cleanup(self: SceneComponent)
	for _, Sequence in self.SequenceComponents do
		(Sequence :: SequenceComponent):Destroy()
	end
end

function SceneComponent.Destroy(self: SceneComponent)
	self:Cleanup()

	table.clear(self :: any)
	setmetatable(self :: any, nil)
end

return {
	new = SceneComponent.new,
}
