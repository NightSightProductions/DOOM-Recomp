// DOOM (2016) settings for the game-agnostic runtime (see game.h).
#include "game.h"

static const char *const doom_args[] = {
    // Always Vulkan: the OpenGL renderer is the game's other executable (DOOMx64.exe), which is not part of
    // this port. A saved r_renderAPI "0" (from picking OpenGL in the Video menu) would otherwise make every
    // launch fail; command-line cvars are applied after the config file, so this wins.
    "+r_renderAPI", "1", NULL,
};

const RtGame rt_game = {
    .name = "DOOM",
    .exe = "DOOMx64vk.exe",
    .win_dir = "C:\\DOOM",
    .data_name = "doom-recomp",
    .log_name = "DOOM-recomp",
    .env_prefix = "DOOM",
    .steam_folder = "DOOM",
    .steam_app_id = 379720,
    .relaunch_prefix = "DOOMx64",
    .extra_args = doom_args,
    .cloud_save_dir = "c/users/Player/Saved Games/id Software/DOOM/base/savegame.user/%llu",
    .cloud_prefix = "doomrecomp/",
    .computer_name = "DOOM-MAC",
    .pick_folder_msg = "Choose your DOOM (2016) game folder: the one that contains DOOMx64vk.exe.",
};
