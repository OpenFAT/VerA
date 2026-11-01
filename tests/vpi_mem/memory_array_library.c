/* The VPI analog library over a device with a memory-backed array
 * (memory_array_library.va): an operating point, no calls.
 *! analysis op
 */
#include "vpi_user.h"
static void reg(void) {}
void (*vlog_startup_routines[])(void) = {reg, 0};
