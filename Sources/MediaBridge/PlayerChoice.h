// PlayerChoice — which registered now-playing player the bridge shows.
// Pure C so it can be tested without any player (Tools/player-choice-test).

#pragma once
#include <stdbool.h>

enum { PlayerStateUnknown = -1, PlayerStatePlaying = 1 };

/// `states[i]`: player i's MRPlaybackState (1 = playing), or -1 when it did
/// not answer. `recentlyPlaying[i]`: it was seen playing within the last few
/// seconds. `isMusic[i]`: a music app (not a browser or video player).
/// `mainIndex`: the system's now-playing app; `shownIndex`: the player shown
/// now (-1 = none); `pinned`: the shown player was controlled from OmniHub
/// (play / pause / next …) since it was chosen. Returns the index to show,
/// -1 for none.
///
/// 1. While a music app plays, only music apps are candidates: with music
///    and a video playing together, the music is shown and controlled.
/// 2. Among the candidates a player that just started wins — the one play
///    was just pressed on (the system's app if several started together).
/// 3. Otherwise the shown player stays while it plays (or did not answer
///    but was playing a moment ago): the system hands Now Playing back and
///    forth between two players playing at once, and following it would
///    swap the shown player every few seconds.
/// 4. With no music playing, a pinned player stays even when paused:
///    pausing the music from OmniHub keeps it shown, so play resumes it.
/// 5. Then the system's app if it is a candidate, then any candidate.
/// 6. With nothing playing the shown player stays, else the system's app.
static inline int omnihub_choose_player(const int *states, const bool *recentlyPlaying, const bool *isMusic,
                                        int count, int mainIndex, int shownIndex, bool pinned) {
    bool musicPlays = false;
    for (int i = 0; i < count; i++) {
        if (states[i] == PlayerStatePlaying && isMusic[i]) musicPlays = true;
    }
#define OMNIHUB_CANDIDATE(i) (states[(i)] == PlayerStatePlaying && (!musicPlays || isMusic[(i)]))
    int started = -1;
    for (int i = 0; i < count; i++) {
        if (OMNIHUB_CANDIDATE(i) && !recentlyPlaying[i] && (started < 0 || i == mainIndex)) started = i;
    }
    int pick = -1;
    if (started >= 0) {
        pick = started;
    } else if (shownIndex >= 0
               && (OMNIHUB_CANDIDATE(shownIndex)
                   || (states[shownIndex] == PlayerStateUnknown && recentlyPlaying[shownIndex]
                       && (!musicPlays || isMusic[shownIndex])))) {
        pick = shownIndex;
    } else if (!musicPlays && pinned && shownIndex >= 0) {
        pick = shownIndex;
    } else if (mainIndex >= 0 && OMNIHUB_CANDIDATE(mainIndex)) {
        pick = mainIndex;
    } else {
        for (int i = 0; i < count && pick < 0; i++) {
            if (OMNIHUB_CANDIDATE(i)) pick = i;
        }
        if (pick < 0) pick = shownIndex >= 0 ? shownIndex : mainIndex;
    }
#undef OMNIHUB_CANDIDATE
    return pick;
}
