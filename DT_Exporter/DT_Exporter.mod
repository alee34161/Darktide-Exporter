return {
	run = function()
		fassert(rawget(_G, "new_mod"), "`DT_Exporter` encountered an error loading the Darktide Mod Framework.")

		new_mod("DT_Exporter", {
			mod_script       = "DT_Exporter/scripts/mods/DT_Exporter/DT_Exporter",
			mod_data         = "DT_Exporter/scripts/mods/DT_Exporter/DT_Exporter_data",
			mod_localization = "DT_Exporter/scripts/mods/DT_Exporter/DT_Exporter_localization",
		})
	end,
	packages = {},
}
