/*
 * Copyright (c) 2013-2014 Tito Latini
 *
 * This program is free software; you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation; either version 2 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program; if not, write to the Free Software
 * Foundation, Inc., 51 Franklin St, Fifth Floor, Boston, MA  02110-1301  USA
 *
 */

#include <unistd.h>
#include <stdlib.h>
#include <stdio.h>
#include <signal.h>
#include <string.h>
#include "rtpa.h"

static void pa_set_error_msg(const char *msg)
{
        strncpy(pa_error_msg, msg, PA_ERROR_MSG_MAX_LENGTH);
}

static void *pa_process_thread(void *arg)
{
        (void) arg;

        if (Pa_StartStream(stream) != paNoError) {
                fprintf(stderr, "PA_StartStream failed\n");
                return 0;
        }
        pa_status = PA_RUNNING;

        while(pa_status == PA_RUNNING) {
                if (pa_lisp_busy) {
                        pa_cycle_begin();
                        memset(pa_outputs_anchor, 0, pa_outbuf_bytes);
                        pa_cycle_end(frames_per_buffer);
                } else {
                        /*
                         * Transfer the control of the client to lisp realtime
                         * thread and block the current thread.
                         * Notice it is called ONLY ONE TIME after the first
                         * cycle and ONLY ONE TIME after the gc in SBCL.
                         * Practically, this thread is an emergency exit when we
                         * use an implementation of Common Lisp with a gc which
                         * stops the rt lisp thread. If the implementation of CL
                         * has a realtime gc, there aren't other transfers of
                         * the control from C to Lisp and vice versa.
                         */
                        __pa_condition_signal(&pa_lisp_cond, &pa_lisp_lock);
                        __pa_condition_wait(&pa_c_cond, &pa_c_lock);
                }
        }
        return 0;
}

char *pa_get_error_msg(void)
{
        return pa_error_msg;
}

/* Wait on the lisp realtime thread */
void pa_condition_wait(void)
{
        __pa_condition_wait(&pa_lisp_cond, &pa_lisp_lock);
}

/* Lisp rt thread is busy ? */
void pa_set_lisp_busy_state(int status)
{
        pa_lisp_busy = status;
}

/* Transfer the control of the client to C realtime thread */
void pa_transfer_to_c_thread(void)
{
        pa_lisp_busy = 1;
        __pa_condition_signal(&pa_c_cond, &pa_c_lock);
}

int pa_get_buffer_size(void)
{
        return frames_per_buffer;
}

SAMPLE pa_get_sample_rate(void)
{
        return pa_sample_rate;
}

int pa_initialize(unsigned int input_channels, unsigned int output_channels,
                  unsigned long nframes, const char* client_name)
{
        double srate = -1.0;
        PaStreamParameters input_param, *iparam = NULL;
        PaStreamParameters output_param, *oparam = NULL;
        PaStreamInfo *stream_info;
        PaDeviceIndex count;
        PaError err;
        sigset_t sset;

#ifdef PA_HAVE_JACK
        PaJack_SetClientName(client_name);    
#else
        (void) client_name;
#endif

        if (Pa_Initialize() != paNoError) {
                pa_set_error_msg("Pa_Initialize failed");
                return 1;
        }
        pa_in_channels = input_channels;
        pa_out_channels = output_channels;

        count = Pa_GetDeviceCount();
        if (pa_output_id >= 0 && pa_output_id < count)
                output_param.device = pa_output_id;
        else
                output_param.device = Pa_GetDefaultOutputDevice();

        if (output_param.device != paNoDevice) {
                output_param.channelCount = output_channels;
                output_param.sampleFormat = paFloat32;
                output_param.suggestedLatency =
                    Pa_GetDeviceInfo(output_param.device)->defaultLowOutputLatency;
                output_param.hostApiSpecificStreamInfo = NULL;
                oparam = &output_param;
                srate = Pa_GetDeviceInfo(output_param.device)->defaultSampleRate;
        }
        if (pa_input_id >= 0 && pa_input_id < count)
                input_param.device = pa_input_id;
        else
                input_param.device = Pa_GetDefaultInputDevice();

        if (input_param.device != paNoDevice) {
                input_param.channelCount = input_channels;
                input_param.sampleFormat = paFloat32;
                input_param.suggestedLatency =
                    Pa_GetDeviceInfo(input_param.device)->defaultLowInputLatency;
                input_param.hostApiSpecificStreamInfo = NULL;
                iparam = &input_param;
                if (srate <= 0)
                        srate = Pa_GetDeviceInfo(input_param.device)->defaultSampleRate;
        }
        err = Pa_IsFormatSupported(iparam, oparam, srate);
        if (err != paNoError) {
                pa_set_error_msg(Pa_GetErrorText(err));
                Pa_Terminate();
                return 1;
        }
        err = Pa_OpenStream(&stream, iparam, oparam, srate, nframes, paClipOff,
                            NULL, NULL);
        if (err != paNoError) {
                pa_set_error_msg("PA_OpenStream failed");
                Pa_Terminate();
                return 1;
        }
        /* Unblock signals */
        sigemptyset(&sset);
        if (sigprocmask(SIG_SETMASK, &sset, NULL) < 0) {
                pa_set_error_msg("Unblock signals error");
                Pa_Terminate();
                return 1;
        }
        pa_inputs = (float *) malloc(nframes * input_channels * sizeof(float));
        if (pa_inputs == NULL) {
                pa_set_error_msg("malloc of input buffer failed");
                Pa_Terminate();
                return 1;
        }
        pa_frame_bytes = output_channels * sizeof(float);
        pa_outbuf_bytes = nframes * pa_frame_bytes;
        pa_outputs = (float *) malloc(pa_outbuf_bytes);
        if (pa_outputs == NULL) {
                pa_set_error_msg("malloc of output buffer failed");
                Pa_Terminate();
                free(pa_inputs);
                return 1;
        }
        stream_info = (PaStreamInfo *) Pa_GetStreamInfo(stream);
        pa_sample_rate = (SAMPLE) stream_info->sampleRate;
        frames_per_buffer = nframes;
        pa_inputs_anchor = pa_inputs;
        pa_outputs_anchor = pa_outputs;
        pa_lisp_busy = 1;
        return err;
}

int pa_start(void)
{
        int err;

        /*
         * Auxiliary C realtime thread. If lisp is busy, it continues the work
         * to avoid xruns.
         */
        if ((err = pthread_create(&process_thread, NULL, pa_process_thread,
                                  NULL))) {
                pa_set_error_msg("Failed to create the C realtime thread");
                pa_stop(NULL);
                return err;
        }
        return 0;
}

int pa_stop(void *arg)
{
        PaError err;
        (void) arg;

        if (pa_status != PA_RUNNING)
                return 0;

        pa_status = PA_STOPPED;
        pthread_join(process_thread, NULL);

        if ((err = Pa_StopStream(stream)) != paNoError)
                pa_set_error_msg("PA_StopStream failed");
        else if ((err = Pa_CloseStream(stream)) != paNoError)
                pa_set_error_msg("PA_CloseStream failed");

        Pa_Terminate();

        if (pa_inputs_anchor != NULL) {
                free(pa_inputs_anchor);
                pa_inputs_anchor = NULL;
        }
        if (pa_outputs_anchor != NULL) {
                free(pa_outputs_anchor);
                pa_outputs_anchor = NULL;
        }
        return err;
}

void pa_set_lisp_io(SAMPLE *input, SAMPLE *output)
{
        lisp_input = input;
        lisp_output = output;
}

unsigned long pa_cycle_begin(void)
{
        int i;
        signed long nframes;
        SAMPLE *tmp;

        if (pa_status != PA_RUNNING)
                return 0;

        if ((nframes = Pa_GetStreamReadAvailable(stream)) < 0)
                return 0;
        else if (nframes == 0 || nframes > frames_per_buffer)
                nframes = frames_per_buffer;

        pa_inputs = pa_inputs_anchor;
        /* Blocking only when Pa_GetStreamReadAvailable returns zero. */
        Pa_ReadStream(stream, pa_inputs, nframes);
        tmp = lisp_input;
        for (i = 0; i < nframes * pa_in_channels; i++)
                *tmp++ = (SAMPLE) *pa_inputs++;
        return nframes;
}

void pa_cycle_end(unsigned long nframes)
{
        int i;
        signed long remain;
        SAMPLE *tmp;

        if ((remain = frames_per_buffer - nframes) > 0)
                memset(pa_outputs_anchor + nframes, 0,
                       remain * pa_frame_bytes); /* zero padding */
        pa_outputs = pa_outputs_anchor;
        tmp = lisp_output;
        for (i = 0; i < nframes * pa_out_channels; i++) {
                *pa_outputs++ = (float) *tmp;
                *tmp++ = (SAMPLE) 0.0;
        }
        Pa_WriteStream(stream, pa_outputs_anchor, frames_per_buffer);
}

void pa_set_devices (PaDeviceIndex input, PaDeviceIndex output)
{
        pa_input_id = input;
        pa_output_id = output;
}
