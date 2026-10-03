return {
	run = function()
		fassert(rawget(_G, "new_mod"), "`PDI_Exporter` encountered an error loading the Darktide Mod Framework.")
		new_mod("PDI_Exporter", {
			mod_script       = "PDI_Exporter/scripts/mods/PDI_Exporter/PDI_Exporter",
			mod_data         = "PDI_Exporter/scripts/mods/PDI_Exporter/PDI_Exporter_data",
			mod_localization = "PDI_Exporter/scripts/mods/PDI_Exporter/PDI_Exporter_localization",
		})
	end,
	packages = {},
}
