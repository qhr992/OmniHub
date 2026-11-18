// Checks Sources/MediaBridge/PlayerChoice.h: which player the now-playing
// bridge shows. Run by test.sh.
#include <stdio.h>
#include "../../Sources/MediaBridge/PlayerChoice.h"

static int failures = 0;

static void check(const char *name, int got, int want) {
    if (got != want) failures++;
    printf("%s  %s", got == want ? "PASS" : "FAIL", name);
    if (got != want) printf("  — got %d, want %d", got, want);
    printf("\n");
}

int main(void) {
    enum { P = 1, PAUSED = 2, NONE = -1 };
    // Player 0 = music app, 1 = video (browser / YouTube).
    const bool mv[] = {true, false};
#define CHOOSE(states, recent, main, shown, pinned) omnihub_choose_player(states, recent, mv, 2, main, shown, pinned)
    {   int s[] = {P, P}; bool r[] = {false, false};
        check("music and video start together: the music is shown", CHOOSE(s, r, 1, -1, false), 0); }
    {   int s[] = {P, P}; bool r[] = {true, true};
        check("both playing, Now Playing moves to the video: the music stays shown", CHOOSE(s, r, 1, 0, false), 0); }
    {   int s[] = {P, P}; bool r[] = {true, false};
        check("a video started while music plays: the music stays shown", CHOOSE(s, r, 1, 0, false), 0); }
    {   int s[] = {P, P}; bool r[] = {false, true};
        check("music started while a video plays: the music is shown", CHOOSE(s, r, 1, 1, false), 0); }
    {   int s[] = {PAUSED, P}; bool r[] = {true, true};
        check("both playing, the music paused from OmniHub: the music stays shown", CHOOSE(s, r, 1, 0, true), 0); }
    {   int s[] = {PAUSED, P}; bool r[] = {true, true};
        check("the music paused in its own app: the video still playing is shown", CHOOSE(s, r, 1, 0, false), 1); }
    {   int s[] = {PAUSED, P}; bool r[] = {true, false};
        check("pinned paused music, then a video started anew: the video is shown", CHOOSE(s, r, 1, 0, true), 1); }
    {   int s[] = {P, PAUSED}; bool r[] = {true, true};
        check("a video paused from OmniHub while music plays: the music is shown", CHOOSE(s, r, 0, 1, true), 0); }
    {   int s[] = {PAUSED, PAUSED}; bool r[] = {true, true};
        check("nothing plays: the shown player stays", CHOOSE(s, r, 0, 1, false), 1); }
    {   int s[] = {NONE, P}; bool r[] = {true, true};
        check("the shown music does not answer once: it stays", CHOOSE(s, r, 1, 0, false), 0); }
    {   int s[] = {NONE, P}; bool r[] = {false, true};
        check("a silent player that was not playing is not kept", CHOOSE(s, r, 1, 0, false), 1); }
    {   int s[] = {PAUSED, PAUSED}; bool r[] = {false, false};
        check("nothing plays, nothing shown yet: the system's app", CHOOSE(s, r, 1, -1, false), 1); }
    {   const bool vv[] = {false, false}; int s[] = {P, P}; bool r[] = {true, true};
        check("two videos playing, Now Playing moves: the shown one stays",
              omnihub_choose_player(s, r, vv, 2, 1, 0, false), 0); }
    {   const bool vv[] = {false, false}; int s[] = {P, P}; bool r[] = {true, false};
        check("two videos, one started anew: that one is shown",
              omnihub_choose_player(s, r, vv, 2, 0, 0, false), 1); }
    {   const bool m3[] = {true, true, false}; int s[] = {P, P, P}; bool r[] = {false, false, false};
        check("two music apps start together: the system's app among them",
              omnihub_choose_player(s, r, m3, 3, 1, -1, false), 1); }
    {   const bool m1[] = {false}; int s[] = {PAUSED}; bool r[] = {false};
        check("no system app among the players, nothing plays: none",
              omnihub_choose_player(s, r, m1, 1, -1, -1, false), -1); }
    printf(failures ? "RESULT: %d failed\n" : "RESULT: all passed\n", failures);
    return failures ? 1 : 0;
}
