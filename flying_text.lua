local flying_text = {}

function flying_text.create_flying_text_entities(surface, position, flying_text_infos)
	if not surface or not position or not flying_text_infos then
		return
	end

	local offset = 0
	for itemname, info in pairs(flying_text_infos) do
		local sign = (info.amount > 0) and "       +" or "        "
		surface.create_entity(
			{
				name = "autobuild-flying-text",
				position = { position.x - 0.5 , position.y + (offset or 0) },
				text = {"", sign, info.amount, " ", game.item_prototypes[itemname].localised_name, " (", info.total ,")"},
				color = { r = 1, g = 1, b = 1 } -- white
			})
		offset = offset - 0.5
	end
end

return flying_text