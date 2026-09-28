using System.IO;
using UnityEditor;
using UnityEngine;

namespace PSXSUS.EditorTools
{
    /// <summary>
    /// One-click setup for PSXSUS's scene list, plus a check that it is right.
    ///
    /// SplashEdit's control panel keeps its scene list in <see cref="EditorPrefs"/>,
    /// keyed by a hash of the project path — so it is per-machine registry state
    /// rather than anything in the repository. That means a fresh clone opens with
    /// an EMPTY scene list, and the generated scenes have to be added by hand in
    /// the right order.
    ///
    /// The order is load-bearing and fails silently when wrong. `psxsus_protocol.lua`
    /// turns a map id into a scene INDEX (`SCENE.GAME + mapId`), and the console
    /// resolves that index against this list. Get it wrong and `Scene.Load` loads a
    /// perfectly valid different scene: pressing start drops everybody into the
    /// lobby again, or into the wrong ship, with no error anywhere.
    ///
    /// So: this writes the list, and <see cref="CheckSceneOrder"/> says plainly
    /// what is wrong if it has drifted.
    /// </summary>
    public static class PSXSUSSetup
    {
        /// The scene order the Lua expects. Index in this array IS the scene
        /// index the console loads.
        private static readonly string[] SceneOrder =
        {
            "Assets/Scenes/SCN_Menu.unity",       // 0  SCENE.MENU
            "Assets/Scenes/SCN_Lobby.unity",      // 1  SCENE.LOBBY
            "Assets/Scenes/SCN_Game_Hulk.unity",  // 2  SCENE.GAME + 0
            "Assets/Scenes/SCN_Game_Rim.unity",   // 3  SCENE.GAME + 1
            "Assets/Scenes/SCN_Game_Core.unity",  // 4  SCENE.GAME + 2
        };

        private static string Prefix =>
            "SplashEdit_" + Application.dataPath.GetHashCode().ToString("X8") + "_";

        [MenuItem("PSXSUS/Set Up Scene List", priority = 0)]
        public static void SetUpSceneList()
        {
            int missing = 0;
            foreach (string path in SceneOrder)
            {
                if (!File.Exists(path))
                {
                    Debug.LogError($"PSXSUS: {path} does not exist. Run " +
                                   "`python PSXSUS/Art/make_scenes.py` first.");
                    missing++;
                }
            }
            if (missing > 0) return;

            EditorPrefs.SetInt(Prefix + "SceneCount", SceneOrder.Length);
            for (int i = 0; i < SceneOrder.Length; i++)
            {
                EditorPrefs.SetString(Prefix + $"Scene_{i}", SceneOrder[i]);
            }

            Debug.Log($"PSXSUS: scene list set to {SceneOrder.Length} scenes in " +
                      "menu / lobby / hulk / rim / core order. Reopen the SplashEdit " +
                      "control panel (Ctrl+Shift+L) to see it.");
            CheckSceneOrder();
        }

        [MenuItem("PSXSUS/Check Scene Order", priority = 1)]
        public static void CheckSceneOrder()
        {
            int count = EditorPrefs.GetInt(Prefix + "SceneCount", 0);
            if (count == 0)
            {
                Debug.LogWarning("PSXSUS: the SplashEdit scene list is empty. " +
                                 "Run PSXSUS > Set Up Scene List.");
                return;
            }

            bool ok = true;
            for (int i = 0; i < SceneOrder.Length; i++)
            {
                string actual = i < count ? EditorPrefs.GetString(Prefix + $"Scene_{i}", "") : "";
                if (actual != SceneOrder[i])
                {
                    // Name the CONSEQUENCE, not just the mismatch: "index 2 is
                    // wrong" is a fact, "starting a game will load the lobby" is
                    // the thing that will actually be observed.
                    string consequence = i switch
                    {
                        0 => "the disc will not boot into the title screen",
                        1 => "PLAY ONLINE will load the wrong scene",
                        _ => $"starting a game on map {i - 2} will load the wrong scene",
                    };
                    Debug.LogError($"PSXSUS: scene {i} should be {SceneOrder[i]} but is " +
                                   $"'{actual}' — {consequence}.");
                    ok = false;
                }
            }
            if (count != SceneOrder.Length)
            {
                Debug.LogError($"PSXSUS: the scene list has {count} entries, expected " +
                               $"{SceneOrder.Length}.");
                ok = false;
            }
            if (ok) Debug.Log("PSXSUS: scene order is correct.");
        }
    }
}
