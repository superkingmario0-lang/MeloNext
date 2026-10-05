using System;

namespace Ryujinx.Common.Configuration
{
    public static class NextendoIdentityState
    {
        private static readonly object Lock = new();
        private static ulong _pid;
        private static string _nexToken = "";
        private static string _profileUserId = "";

        public static void Set(ulong pid, string nexToken, string profileUserId)
        {
            lock (Lock)
            {
                if (pid == 0 || string.IsNullOrEmpty(nexToken) || string.IsNullOrEmpty(profileUserId))
                {
                    _pid = 0;
                    _nexToken = "";
                    _profileUserId = "";
                    return;
                }

                _pid = pid;
                _nexToken = nexToken;
                _profileUserId = profileUserId;
            }
        }

        public static ulong PidFor(string profileUserId)
        {
            lock (Lock)
            {
                return IsBoundToProfile(profileUserId) ? _pid : 0;
            }
        }

        public static string NexTokenFor(string profileUserId)
        {
            lock (Lock)
            {
                return IsBoundToProfile(profileUserId) ? _nexToken : "";
            }
        }

        private static bool IsBoundToProfile(string profileUserId)
        {
            return _pid != 0
                && !string.IsNullOrEmpty(_nexToken)
                && !string.IsNullOrEmpty(_profileUserId)
                && string.Equals(_profileUserId, profileUserId, StringComparison.OrdinalIgnoreCase);
        }
    }
}