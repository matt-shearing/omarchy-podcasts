.pragma library

// Fork addition. The bar builds one panel per monitor, and `.pragma library`
// makes this one shared copy for all of them. Only the panel holding it
// reattaches to an mpv left running by a previous shell, so two panels never
// both drive one player (two position writers, a double auto-advance).

var owner = null

function claim(panel) {
  if (owner === null || owner === panel) {
    owner = panel
    return true
  }
  return false
}

function take(panel) {
  owner = panel
}

function release(panel) {
  if (owner === panel) owner = null
}
