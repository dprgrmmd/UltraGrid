/**
 * @file   video_capture/syphon.mm
 * @author Martin Pulec     <pulec@cesnet.cz>
 */
/*
 * Copyright (c) 2017 CESNET z.s.p.o.
 * All rights reserved.
 *
 * Redistribution and use in source and binary forms, with or without
 * modification, is permitted provided that the following conditions
 * are met:
 *
 * 1. Redistributions of source code must retain the above copyright
 *    notice, this list of conditions and the following disclaimer.
 *
 * 2. Redistributions in binary form must reproduce the above copyright
 *    notice, this list of conditions and the following disclaimer in the
 *    documentation and/or other materials provided with the distribution.
 *
 * 3. Neither the name of CESNET nor the names of its contributors may be
 *    used to endorse or promote products derived from this software without
 *    specific prior written permission.
 *
 * THIS SOFTWARE IS PROVIDED BY THE AUTHORS AND CONTRIBUTORS
 * "AS IS" AND ANY EXPRESSED OR IMPLIED WARRANTIES, INCLUDING,
 * BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY
 * AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO
 * EVENT SHALL THE AUTHORS OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT,
 * INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
 * (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR
 * SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION)
 * HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
 * CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR
 * OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE,
 * EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 */
/**
 * @todo
 * get rid of GLUT (currently it is needed because we need to operate from within
 * mainloop for which is GLUT useful, better solution would be to deploy native
 * Apple mainloop)
 */

#ifdef HAVE_CONFIG_H
#include "config.h"
#include "config_unix.h"
#include "config_win32.h"
#endif

#include <condition_variable>
#include <chrono>
#include <GLUT/glut.h>
#include <mutex>
#include <OpenGL/gl.h>
#include <OpenGL/OpenGL.h> // CGL
#include <OpenGL/glext.h>
#include <queue>
#include <Syphon/Syphon.h>

#include "debug.h"
#include "gl_context.h"
#include "host.h"
#include "lib_common.h"
#include "video.h"
#include "video_capture.h"

using std::condition_variable;
using std::mutex;
using std::queue;
using std::unique_lock;

#define FPS 30.0

/**
 * Class state_vidcap_syphon must be value-initialized
 */
struct state_vidcap_syphon {
        struct video_desc saved_desc;
        SyphonClient *client;
        int window = -1;
        mutex lock;
        condition_variable frame_ready_cv;
        queue<video_frame *> q;

        GLuint fbo_id;
        GLuint tex_id;

        NSString *appName;
        NSString *serverName;

        double override_fps;

        std::chrono::steady_clock::time_point t0 = std::chrono::steady_clock::now();
        int frames;

        ~state_vidcap_syphon() {
                [appName release];
                [serverName release];
                [client release];

                while (q.size() > 0) {
                        video_frame *f = q.front();
                        q.pop();
                        vf_free(f);
                }
        }
};

static struct state_vidcap_syphon *state_global;

static void reconfigure(state_vidcap_syphon *s, struct video_desc desc) {
        glBindTexture(GL_TEXTURE_2D, s->tex_id);
        glTexImage2D(GL_TEXTURE_2D, 0, GL_RGB, desc.width, desc.height, 0, GL_RGB, GL_UNSIGNED_BYTE, NULL);

        glBindFramebufferEXT(GL_FRAMEBUFFER, s->fbo_id);
        glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0_EXT, GL_TEXTURE_2D, s->tex_id, 0);

        glDrawBuffer(GL_COLOR_ATTACHMENT0_EXT);

        glMatrixMode( GL_MODELVIEW );

        glLoadIdentity( );
        glMatrixMode( GL_PROJECTION );
        glLoadIdentity( );
        glViewport( 0, 0, ( GLint ) desc.width, ( GLint ) desc.height );

        glOrtho(0, desc.width, 0, desc.height, 10, -10);
}

static void oneshot_init(int value [[gnu::unused]])
{
        state_vidcap_syphon *s = state_global;

        // Although initialization happens only once, it is important that
        // timer is periodically triggered because only then is glutCheckLoop()
        // left (without that, glutCheckLoop would block infinitely).
        glutTimerFunc(100, oneshot_init, 0);

        // if we are already initialized, exit
        if (s->client)
                return;

        glEnable(GL_TEXTURE_2D);
        glEnable(GL_TEXTURE_RECTANGLE_ARB);

        glGenFramebuffersEXT(1, &s->fbo_id);
        glGenTextures(1, &s->tex_id);

        NSArray *descriptions;
        if (s->appName || s->serverName) {
                descriptions = [[SyphonServerDirectory sharedDirectory] serversMatchingName:@"uv" appName:nil];
        } else {
                descriptions = [[SyphonServerDirectory sharedDirectory] servers];
        }

        if ([descriptions count] == 0) {
                LOG(LOG_LEVEL_ERROR) << "[Syphon capture] No server(s) found!\n";
                return;
        }

        if (!s->override_fps) {
                LOG(LOG_LEVEL_WARNING) << "[Syphon capture] FPS set to " << FPS << ". Use override_fps to override if you know FPS of the server.\n";
        }

        s->client = [[SyphonClient alloc] initWithServerDescription:[descriptions lastObject] options:nil newFrameHandler:^(SyphonClient *client) {
                if ([client hasNewFrame] == NO)
                        return;

                SyphonImage *img = [client newFrameImageForContext: CGLGetCurrentContext()];
                unsigned int width = [img textureSize].width;
                unsigned int height = [img textureSize].height;

                struct video_desc d{width, height, RGB, s->override_fps ? s->override_fps : FPS, PROGRESSIVE, 1};
                if (!video_desc_eq(s->saved_desc, d)) {
                        reconfigure(s, d);
                        s->saved_desc = d;
                }

                struct video_frame *f = vf_alloc_desc_data(d);

                glBindTexture(GL_TEXTURE_RECTANGLE_ARB, [img textureName]);
                glBegin(GL_QUADS);
                glTexCoord2i(0, height);     glVertex2i(0, 0);
                glTexCoord2i(0, 0);          glVertex2i(0, height);
                glTexCoord2i(width, 0);      glVertex2i(width, height);
                glTexCoord2i(width, height); glVertex2i(width, 0);
                glEnd();

                glReadPixels(0, 0, width, height, GL_RGB, GL_UNSIGNED_BYTE, f->tiles[0].data);
                gl_check_error();

                [img release];

                unique_lock<mutex> lk(s->lock);
                bool pushed = false;
                if (s->q.size() == 0) {
                        s->q.push(f);
                        pushed = true;
                } else {
                        LOG(LOG_LEVEL_WARNING) << "[Syphon capture] Skipping frame.\n";
                        vf_free(f);
                }
                lk.unlock();

                if (pushed) {
                        s->frame_ready_cv.notify_one();
                        debug_msg("[Syphon capture] Frame acquired.\n");
                }
        }];

        if (!s->client) {
                LOG(LOG_LEVEL_ERROR) << "[Syphon capture] Client could have not been created!\n";
        } else {
                NSDictionary *dict = [s->client serverDescription];
                LOG(LOG_LEVEL_NOTICE) << "[Syphon capture] Using server - app: " <<
                        [[dict objectForKey:@"SyphonServerDescriptionAppNameKey"] UTF8String] << " name: " <<
                        [[dict objectForKey:@"SyphonServerDescriptionNameKey"] UTF8String] << "\n";
        }
}

static void noop()
{
}

static void syphon_mainloop(void *state)
{
        state_global = (struct state_vidcap_syphon *) state;
        struct state_vidcap_syphon *s = state_global;

        glutInit(&uv_argc, uv_argv);
        glutInitDisplayMode(GLUT_RGB);
        s->window = glutCreateWindow("dummy Syphon client window");
        glutHideWindow();

        glutDisplayFunc(noop);
        glutTimerFunc(100, oneshot_init, 0);

        while (!should_exit) {
                glutCheckLoop();
        }
}

static void usage()
{
        printf("\t-t syphon[:name=<server_name>][:app=<app_name>][:override_fps=<fps>]\n");
        printf("\n");
        printf("\tname\n\t\tsyphon server name\n");
        printf("\tname\n\t\tsyphon server application name\n");
        printf("\toverride_fps\n\t\toverrides FPS in metadata (but not the actual rate captured)\n");
}

static int vidcap_syphon_init(const struct vidcap_params *params, void **state)
{
        state_vidcap_syphon *s = new state_vidcap_syphon();

        char *opts = strdup(vidcap_params_get_fmt(params));
        char *item, *save_ptr;
        int ret = VIDCAP_INIT_OK;

        item = strtok_r(opts, ":", &save_ptr);
        while (item) {
                if (strcmp(item, "help") == 0) {
                        usage();
                        ret = VIDCAP_INIT_NOERR;
                        break;
                } else if (strstr(item, "app=") == item) {
                        s->appName = [NSString stringWithCString: item + strlen("app=") encoding:NSASCIIStringEncoding];
                } else if (strstr(item, "name=") == item) {
                        s->serverName = [NSString stringWithCString: item + strlen("name=") encoding:NSASCIIStringEncoding];
                } else if (strstr(item, "override_fps=") == item) {
                        s->override_fps = atof(item + strlen("override_fps="));
                } else {
                        LOG(LOG_LEVEL_ERROR) << "Syphon: Unknown argument - " << item << "\n";
                        ret = VIDCAP_INIT_FAIL;
                        break;
                }
                item = strtok_r(NULL, ":", &save_ptr);
        }

        free(opts);

        if (ret != VIDCAP_INIT_OK) {
                delete s;
                return ret;
        }

        register_mainloop(syphon_mainloop, s);

        *state = s;

        return VIDCAP_INIT_OK;
}

static void vidcap_syphon_done(void *state)
{
        state_vidcap_syphon *s = (state_vidcap_syphon *) state;

        if (s->window != -1) {
                glutDestroyWindow(s->window);
        }

        if (s->tex_id != 0) {
                glDeleteTextures(1, &s->tex_id);
        }

        if (s->fbo_id != 0) {
                glDeleteFramebuffersEXT(1, &s->fbo_id);
        }

        delete s;
}

static struct video_frame *vidcap_syphon_grab(void *state, struct audio_frame **audio)
{
        state_vidcap_syphon *s = (state_vidcap_syphon *) state;
        struct video_frame *ret = NULL;

        unique_lock<mutex> lk(s->lock);
        s->frame_ready_cv.wait_for(lk, std::chrono::milliseconds(100), [s]{return s->q.size() > 0;});
        if (s->q.size() > 0) {
                ret = s->q.front();
                s->q.pop();
                ret->dispose = vf_free;

                // statistics
                s->frames++;
                std::chrono::steady_clock::time_point now = std::chrono::steady_clock::now();
                double seconds = std::chrono::duration_cast<std::chrono::microseconds>(now - s->t0).count() / 1000000.0;
                if (seconds >= 5) {
                        LOG(LOG_LEVEL_INFO) << "[Syphon capture] " << s->frames << " frames in "
                                << seconds << " seconds = " <<  s->frames / seconds << " FPS\n";
                        s->t0 = now;
                        s->frames = 0;
                }
        }

        *audio = NULL;
        return ret;
}

static struct vidcap_type *vidcap_syphon_probe(bool verbose)
{
        UNUSED(verbose);
        struct vidcap_type *vt;

        vt = (struct vidcap_type *) calloc(1, sizeof(struct vidcap_type));
        if (vt != NULL) {
                vt->name = "syphon";
                vt->description = "Syphon capture client";
        }
        return vt;
}

static const struct video_capture_info vidcap_syphon_info = {
        vidcap_syphon_probe,
        vidcap_syphon_init,
        vidcap_syphon_done,
        vidcap_syphon_grab,
};

REGISTER_MODULE(syphon, &vidcap_syphon_info, LIBRARY_CLASS_VIDEO_CAPTURE, VIDEO_CAPTURE_ABI_VERSION);

