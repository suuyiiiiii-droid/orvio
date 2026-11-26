using System.Collections.Generic;
using T1Controller;
using Xunit;

public sealed class AudioMuteTests
{
    [Fact] public void MixedSessionsBecomeMutedTogetherAndNextPressUnmutesAll()
    {
        Assert.True(AudioMutePolicy.Target([false, true, false]));
        Assert.False(AudioMutePolicy.Target([true, true, true]));
    }
    [Fact] public void AudioHelpersBelongOnlyToTheirVerifiedPlayerAncestor()
    {
        var roots = new HashSet<uint> { 10 };
        var parents = new Dictionary<uint, uint> { [11] = 10, [12] = 11, [21] = 20, [30] = 31, [31] = 30 };
        Assert.True(AudioMutePolicy.BelongsToPlayer(12, roots, parents));
        Assert.False(AudioMutePolicy.BelongsToPlayer(21, roots, parents));
        Assert.False(AudioMutePolicy.BelongsToPlayer(30, roots, parents));
        Assert.False(AudioMutePolicy.BelongsToPlayer(0, roots, parents));
    }
}

public sealed class NativeVoiceRouteTests
{
    [Fact] public void NativeHardwareNeverStartsASecondRecorderAndDictationNeverExecutesCommands()
    {
        Assert.Equal(VoiceInputDestination.System, RemoteModes.VoiceDestination(RemoteMode.Native, true));
        Assert.Equal(VoiceInputDestination.Text, RemoteModes.VoiceDestination(RemoteMode.Native, false));
        Assert.Equal(VoiceInputDestination.Command, RemoteModes.VoiceDestination(RemoteMode.Media, true));
        Assert.Equal(VoiceInputDestination.Command, RemoteModes.VoiceDestination(RemoteMode.Host, false));
    }
}
