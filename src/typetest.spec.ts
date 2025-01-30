import { PlayerStoreConfig } from "./store";
import { Lyra } from "./index";
import { t } from "@rbxts/t";

Lyra.create({
    name: "PlayerData",
    template: {
        gold: 0,
        new: "",
    },
    schema: t.interface({
        gold: t.number,
        new: t.string,
    }),
    migrationSteps: [
        Lyra.MigrationStep.addFields("AddNewField", { new: "a" }),
        Lyra.MigrationStep.addFields("AddNewField", { gold: 1 }),
    ],
});
