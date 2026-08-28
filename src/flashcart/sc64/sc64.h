/**
 * @file sc64.h
 * @brief SC64 flashcart support
 * @ingroup flashcart 
 */

#ifndef FLASHCART_SC64_H__
#define FLASHCART_SC64_H__


#include "../flashcart.h"


/**
 * @addtogroup sc64
 * @{
 */

flashcart_t *sc64_get_flashcart (void);

/** Enable/disable the experimental in-game save-state runtime configuration. */
flashcart_err_t sc64_set_savestate_runtime (bool enabled);

/** @} */ /* sc64 */


#endif
