local flying_text = {}

function flying_text.create_flying_text_entities(player, position, flying_text_infos)
	if not player or not position or not flying_text_infos then
		return
	end

	local offset = 0
	for itemname, info in pairs(flying_text_infos) do
		local sign = (info.amount > 0) and "       +" or "        "
    	local display_text = {"", sign, info.amount, " ", prototypes.item[itemname].localised_name, " (", info.total ,")"}
    	player.create_local_flying_text(
			{
				text = display_text,
				position = { position.x, position.y - offset },
				-- color = { r = 1, g = 1, b = 1 }, -- white
				time_to_live = 150,
				speed = 100,
			})
		offset = offset + 0.5
	end
end

return flying_text