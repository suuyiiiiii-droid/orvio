using System;
using System.Collections.Generic;
using System.Linq;

namespace T1Controller;

internal static class AudioMutePolicy
{
    // A player may have multiple WASAPI sessions with different mute states.
    // One key press always puts the whole player in the same state.
    public static bool Target(IEnumerable<bool> states) => states.Any(muted => !muted);

    public static bool BelongsToPlayer(uint pid, ISet<uint> roots, IReadOnlyDictionary<uint, uint> parents)
    {
        var seen = new HashSet<uint>();
        for (var depth = 0; pid > 0 && depth < 32 && seen.Add(pid); depth++)
        {
            if (roots.Contains(pid)) return true;
            if (!parents.TryGetValue(pid, out pid)) return false;
        }
        return false;
    }
}
