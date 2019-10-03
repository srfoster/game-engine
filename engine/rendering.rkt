#lang racket

(provide lux-start
         final-state
         precompiler-entity
         precompile!
         (rename-out [make-precompiler precompiler])
         precompiler?
         register-fonts!
         (struct-out demo)
       ;  set-font!
         recompile!
         force-recompile!
         cleanup-renderer!
         ;MONOSPACE-FONT-FACE
         default-error-port
         error-out-port
         ml-scale-info
         )

(require racket/match
         racket/fixnum
         racket/flonum
         lux
         
         lux/chaos/gui/val

         (prefix-in ml: mode-lambda)
         (prefix-in ml: mode-lambda/static)
         (prefix-in gl: mode-lambda/backend/gl)
         (prefix-in ml: mode-lambda/text/runtime)
         posn)

(require "./core.rkt")
(require "../components/animated-sprite.rkt")

(component precompiler (sprites))

(define debug-message
  #f
  #;"This is a debug message.  Renders on top of any game...")

(define (make-precompiler . animated-sprites-or-images)
  (define entities (filter entity? (flatten animated-sprites-or-images)))

  
  
  (define animated-sprites (flatten
                            (append
                             (map (lambda(e) (get-component e animated-sprite?)) entities)
                             (filter animated-sprite? (flatten animated-sprites-or-images)))))
  
  (define images (filter image? (flatten animated-sprites-or-images)))
  
  (new-precompiler (flatten
                (append (map fast-image images)
                        (map vector->list (map animated-sprite-frames (flatten animated-sprites)))))))


(define (lux-start larger-state)
  (define render-tick (get-mode-lambda-render-tick (game-entities larger-state)))
  (define g-width  (game-width larger-state))
  (define g-height (game-height larger-state))

  (call-with-chaos
   (get-gui #:width g-width #:height g-height)
   (λ () (fiat-lux (demo larger-state render-tick)))))




(define default-error-port (current-error-port))
;(define default-error-handler (error-display-handler))
(define default-error-print-handler (port-print-handler (current-error-port)))
(define error-out-port #f)

(define ml-scale-info #f)

(define (extract-scale-info str)
  (define scale-list (map (compose (curry map string->number)
                                   string-split
                                   string-trim
                                   (curryr string-replace "'" "")
                                   (curryr string-replace "(" "")
                                   (curryr string-replace "#" "")
                                   (curryr string-replace ")" ""))
                          (string-split (string-replace str ")#(" ") #(") ") #(")))
  (drop scale-list (- (length scale-list) 5))
  )

(define (get-mode-lambda-render-tick original-entities)
  (define get-backing-scale (dynamic-require 'racket/gui/base 'get-display-backing-scale))
  ;Assume the last entity is the background entity
  (define bg-entity (last original-entities))

  ;Use the background to setup some helpful constants
  (define W (exact-round (* (w bg-entity) (get-backing-scale))))
  (define H (exact-round (* (h bg-entity) (get-backing-scale))))
  (define W/2 (/ W 2))
  (define H/2 (/ H 2))

  ;Initialize the compiled sprite database
  (register-sprites-from-entities! original-entities)
  (register-fonts-from-entities! original-entities)

  ;Use the entities, plus their sprites, to determine the initial sprite database
  (set! csd (entities->compiled-sprite-database original-entities))

  ;Define that we'll have one layer of sprites (for now).
  ;Fix its position at the center of the screen
  (define layers (vector
                  ; LAYER 0 - MODE7-FLOOR
                  (ml:layer (real->double-flonum W/2)
                            (real->double-flonum H/2)
                            #:horizon -20.0   ; What does this do???
                            #:mode7   2.0
                            #:fov     30.0 ;(* W 0.15)
                            )
                  ; LAYER 1 - MOST ENTITIES
                  (ml:layer (real->double-flonum W/2)
                            (real->double-flonum H/2)
                            ;#:mode7 2.0
                            ;#:horizon 50.0
                            )
                  ; LAYER 2 - TREE TOPS AND ROOF TOPS
                  (ml:layer (real->double-flonum W/2)
                            (real->double-flonum H/2)
                            )
                  ; LAYER 3 - SKY
                  (ml:layer (real->double-flonum W/2)
                            (real->double-flonum H/2)
                            )
                  ; LAYER 4 - UI
                  (ml:layer (real->double-flonum W/2)
                            (real->double-flonum H/2)
                            )
                  ; LAYER 5 - STAR WARS EFFECT LAYER
                  (ml:layer (real->double-flonum W/2)
                            (real->double-flonum H/2)
                            #:horizon 20.0   ; What does this do???
                            #:mode7   2.0
                            #:fov     240.0 ;(* W 0.5) / 240.0
                            )
                  ))

  ;Set up our open gl render function with the current sprite database
  (define ml:render (gl:stage-draw/dc csd W H (vector-length layers)))

  ; ==== START OF ERROR PORT HACK ====
  
  ;Clean up old port if it exists and open a new one
  (if (and error-out-port
           (port-closed? error-out-port))
      (begin (close-output-port error-out-port)
             (set! error-out-port (open-output-bytes)))
      (set! error-out-port (open-output-bytes)))
  
  ;(current-error-port error-out-port)
  #|(define (new-error-handler msg trace)
    (displayln (first (shuffle (list "==== ERROR! YOUR CODE IS NOT PERFECT ===="
                                     "==== IT'S OK, WE ALL MAKE MISTAKES ===="
                                     "==== ARE YOU SURE THAT'S RIGHT? ===="
                                     "==== IF AT FIRST YOU DON'T SUCCEED, TRY, TRY AGAIN ===="
                                     "==== NEVER GIVE UP, NEVER SURRENDER ===="
                                     "==== OOPS! SOMETHING WENT WRONG ===="))))
    ;(displayln msg)
    (if (port-closed? error-out-port)
        (begin ;(displayln "==== ERROR PORT IS CLOSED ====")
               (default-error-handler msg trace))
        (begin (write msg error-out-port)
               (default-error-handler msg trace)))
    )

  (error-display-handler new-error-handler)|#

  (define (new-port-print-handler msg out)  ;used when (eprintf "~v" ...) is called
    (displayln "=== WINDOW SIZE CHANGED ===")
    (displayln msg)
    (if (port-closed? error-out-port)
        (begin ;(displayln "==== ERROR PORT IS CLOSED ====")
               (default-error-print-handler msg out))
        (begin (write msg error-out-port)
               (default-error-print-handler msg out)))
    )
  
  (port-print-handler (current-error-port) new-port-print-handler)

  ; ==== END OF ERROR PORT HACK ====

  
  (define (ticky-tick current-entities)
    
    ;Find uncompiled entities...
    (register-sprites-from-entities! current-entities)
    (register-fonts-from-entities! current-entities)

    ;Recompile the database if we added anything:
    (thread (thunk
             (and (with-handlers ([exn:fail?
                                   (lambda(e) #f)])
                    (recompile!))
                  (set! ml:render (gl:stage-draw/dc csd W H 8)))))

    ;Create our sprites
    (define dynamic-sprites (game->mode-lambda-sprite-list current-entities))

    (define static-sprites (list))

    ; This should capture and flush out mode lambda errors from the previous tick
    (define e-string (bytes->string/utf-8 (get-output-bytes error-out-port #t)))

    ;Actually render them
    ;(parameterize ([current-error-port error-out-port]) ;This isn't working for some reason
      (if (equal? e-string "")
          (ml:render layers
                     static-sprites
                     dynamic-sprites)
          (begin (displayln e-string)
                 (if (string-prefix? e-string "#(#(")
                     (begin (set! ml-scale-info (extract-scale-info e-string))
                            (ml:render layers
                                       static-sprites
                                       dynamic-sprites))
                     (ml:render layers
                                static-sprites
                                dynamic-sprites))))
      ;)
    )

  ticky-tick
  )


(define lux:key-event?     #f)
(define lux:mouse-event-xy #f)
(define lux:mouse-event?   #f)

(define g/v (make-gui/val))
(struct demo
  ( state render-tick)
  #:methods gen:word
  [(define (word-fps w)
     60.0)  ;Changed from 60 to 30, which makes it more smooth on the Chromebooks we use in class.
            ;   Not sure why we were seeing such dramatic framerate drops
   
   (define (word-label s ft)
     (lux-standard-label "Values" ft))
   
   (define (word-output w)
     (match-define (demo  state render-tick) w)

     (get-render render-tick))
   
   (define (word-event w e)
     (set! lux:key-event?  
       (or lux:key-event? (dynamic-require 'lux/chaos/gui/key 'key-event?)))
     (set! lux:mouse-event-xy 
       (or lux:mouse-event-xy (dynamic-require 'lux/chaos/gui/mouse 'mouse-event-xy)))
     (set! lux:mouse-event? 
       (or lux:mouse-event? (dynamic-require 'lux/chaos/gui/mouse 'mouse-event?)))

     (match-define (demo  state render-tick) w)
     (define closed? #f)
     (cond
       [(eq? e 'close)  #f]
       [(lux:key-event? e)

       
        (if (not (eq? 'release (send e get-key-code)))
            (demo  (handle-key-down state (format "~a" (send e get-key-code))) render-tick)
            (demo  (handle-key-up state (format "~a" (send e get-key-release-code))) render-tick))
         
        ]
       [(and (lux:mouse-event? e)
             (send e moving?))
        (let-values ([(mouse-x mouse-y) (lux:mouse-event-xy e)])
          (demo  (handle-mouse-xy state (posn mouse-x mouse-y)) render-tick))
        ]

       [(and (lux:mouse-event? e)
             (send e button-changed?))
        (if (send e button-down?)
            (demo (handle-mouse-down state (send e get-event-type)) render-tick)
            (demo (handle-mouse-up state (send e get-event-type)) render-tick))
        ]
       [else w]))
   
   (define (word-tick w)
     (match-define (demo  state render-tick) w)
     (demo  (tick state) render-tick)
     )])




(define (final-state d)
  (demo-state d))


;(gl:gl-filter-mode 'crt)

(define (get-gui #:width  [w 480]
                 #:height [h 360])
  (define make-gui (dynamic-require 'lux/chaos/gui 'make-gui))
  (make-gui #:start-fullscreen? #f
            #:opengl-hires? #t
            #:frame-style (if (eq? (system-type 'os) 'windows)
                              (list ;'no-resize-border
                                    ;'no-caption
                               )
                              (list ;'no-resize-border
                               )
                              )
            #:mode gl:gui-mode  ; 'gl-core
            #:width w
            #:height h))

(define (get-render render-tick)
  (if last-game-snapshot
          (render-tick (game-entities last-game-snapshot))
          (render-tick '())))


;End bullshit











(require 2htdp/image)


(define (fast-image->id f)
  (string->symbol (~a "id" (fast-image-id f))))

(define (add-animated-sprite-frame-new! db f)
  (define id-sym (fast-image->id f))
  
  (ml:add-sprite!/value db id-sym (fast-image-data f)))

(define (add-animated-sprite-frame! db e as f i)
  (define id-sym (fast-image->id f))
  
  (ml:add-sprite!/value db id-sym (fast-image-data f)))

(define (add-animated-sprite! db e as)
  (define frames (animated-sprite-frames as))
  (for ([f (in-vector frames)]
        [i (in-range (vector-length frames))])
    (add-animated-sprite-frame! db e as f i)))

(define (add-entity! db e)
  (add-animated-sprite! db e (get-component e image-animated-sprite?)))

(define (entities->compiled-sprite-database entities)
  (define sd (ml:make-sprite-db))

  (for ([e (in-list entities)])
    (and (get-component e image-animated-sprite?)
         (add-entity! sd e)))
  
  (define csd (ml:compile-sprite-db sd))



  ;(displayln (ml:compiled-sprite-db-spr->idx csd))
  ; (ml:save-csd! csd (build-path "/Users/thoughtstem/Desktop/sprite-db") #:debug? #t)

  csd)






(require threading)

(define temp-storage '())

(define (remember-image! f)
  (set! temp-storage
        (cons (fast-image-id f)
              temp-storage)))

(define (seen-image-before f)
  (member (fast-image-id f) temp-storage =))

(define (precompiler-entity . is)
  (apply precompile! is))

(define (precompile! . is)
  (define images
    (flatten
     (append
       (map fast-image (filter image? is))
       (map (compose vector->list animated-sprite-frames)
            (flatten (filter identity (filter image-animated-sprite? is))))
       (entities->sprites-to-compile (filter entity? is)))))
  
  (register-sprites-from-images! images)

  #f)

(define should-recompile? #f)
(define compiled-images '())

(define csd       #f)  ;Mode Lambda's representation of our compiled sprites


(define (entities->sprites-to-compile entities)
  (define fast-images-from-animated-sprite
    (~> entities
        (map (curryr get-components image-animated-sprite?) _)
        flatten
        (filter identity _)
        (map (compose vector->list animated-sprite-frames) _)
        flatten))


  (define fast-images-from-precompile-component
    (flatten
     (~> entities
         (map (curryr get-components precompiler?) _)
         flatten
         (map precompiler-sprites _) 
         flatten)))

  

  (append fast-images-from-animated-sprite
          fast-images-from-precompile-component))

(define (entities->fonts-to-register entities)
  (define fonts-from-animated-sprite
    (~> entities
        (map (curryr get-components string-animated-sprite?) _)
        flatten
        (filter identity _)
        (map (compose vector->list animated-sprite-frames) _)
        flatten
        (map text-frame-font _)
        (filter identity _)))

  #|(define fast-images-from-precompile-component
    (flatten
     (~> entities
         (map (curryr get-components precompiler?) _)
         flatten
         (map precompiler-sprites _) 
         flatten)))|#

  fonts-from-animated-sprite)


(define (register-sprites-from-images! images)
  (define uncompiled-images
    (remove-duplicates (filter-not seen-image-before
                                   images)
                       fast-equal?))

  (for ([image (in-list uncompiled-images)])
    (remember-image! image))

  (and (not (empty? uncompiled-images))
       #;
       (displayln "Recompile! Because:")
       #;
       (displayln (map fast-image-data uncompiled-images))
       (set! compiled-images (append compiled-images uncompiled-images))
       (set! should-recompile? #t)))


(define (register-sprites-from-entities! entities)
  ;Trigger recompile if any of the frames haven't been remembered
  (define images (entities->sprites-to-compile entities))

  (register-sprites-from-images! images))

(define (register-fonts-from-entities! entities)
  (define fonts (entities->fonts-to-register entities))
  (apply register-fonts! fonts))

(define (register-fonts! . fonts)
  (define (seen-font-before f)
    (findf (curry font-eq? f) game-fonts))

  (define (object->font f)
    (font (send f get-size)
          (send f get-face)
          (send f get-family)
          (send f get-style)
          (send f get-weight)
          #f
          #f))
  
  (define uncompiled-fonts
    (filter-not seen-font-before
                fonts))

  (and (not (empty? uncompiled-fonts))
       #;
       (displayln "Registering New Fonts:")
       #;
       (displayln (~a (remove-duplicates (map object->font uncompiled-fonts))))
       (set! game-fonts (append game-fonts (remove-duplicates (map object->font uncompiled-fonts))))
       (set! should-recompile? #t)
       ))


(struct font (size face family style weight ml:font renderer) #:transparent)

;(define MONOSPACE-FONT-FACE
;  (cond [(eq? (system-type 'os) 'windows) "Consolas" ]
;        [(eq? (system-type 'os) 'macosx)  "Menlo"]
;        [(eq? (system-type 'os) 'unix)    "DejaVu Sans Mono"]))
  
(define game-fonts
  (list (font 13.0 MONOSPACE-FONT-FACE
              'modern 'normal 'normal
              #f
              #f)))

(define (cleanup-renderer!)
  (displayln "=== CLEANING UP SPRITES ===")
  (set! temp-storage '())
  (set! compiled-images '())
  (set! csd #f)
  #t)

(define (force-recompile!)
  (set! should-recompile? #t)
  (recompile!))

(define (recompile!)
  (define get-backing-scale (dynamic-require 'racket/gui/base 'get-display-backing-scale))
  (and should-recompile?
       (set! should-recompile? #f)
       (let ([sd2 (ml:make-sprite-db)])
         (for ([image (in-list compiled-images)])
           (add-animated-sprite-frame-new! sd2 image))

         
         (define ml:load-font! (dynamic-require 'mode-lambda/text/static 'load-font!))
         
         #;(define the-font
           (ml:load-font! sd2
                          #:size 13.0
                          #:face   "DejaVu Sans Mono"
                          #:family 'modern
                          #:style  'normal
                          #:weight 'normal
                          ;#:smoothing 'unsmoothed
                          ))

         (set! game-fonts
               (map
                (λ(f)
                  (struct-copy font f
                               [ml:font
                                (ml:load-font! sd2
                                               #:scaling (get-backing-scale)
                                               #:size (font-size f)
                                               #:face   (font-face f)
                                               #:family (font-family f)
                                               #:style  (font-style f)
                                               #:weight (font-weight f)
                                               ;#:smoothing 'unsmoothed
                                               )]))
            game-fonts))

         
         (set! csd (ml:compile-sprite-db sd2))

         

         (set! game-fonts
               (map (λ(f)
                      (struct-copy font f
                                   [renderer (ml:make-text-renderer (font-ml:font f) csd)]))
                    game-fonts))

         

         ;(displayln (ml:compiled-sprite-db-spr->idx csd))
         
         
         #t)))

#;(define (set-font! #:size   [size 13]
                   #:face   [face "DejaVu Sans Mono"]
                   #:family [family 'modern]
                   #:style  [style  'normal]
                   #:weight [weight 'normal])
  (define ml:load-font! (dynamic-require 'mode-lambda/text/static 'load-font!))
  (and should-recompile?
       (set! should-recompile? #f)
       (let ([sd2 (ml:make-sprite-db)])
         (for ([image (in-list compiled-images)])
           (add-animated-sprite-frame-new! sd2 image))

         (define the-font (ml:load-font! sd2
                                         #:size size
                                         #:face face
                                         #:family family
                                         #:style  style
                                         #:weight weight))
         (set! csd (ml:compile-sprite-db sd2))
         (set! debug-text-renderer (ml:make-text-renderer the-font csd))
         #t)))
  




(require racket/math)
(define (game->mode-lambda-sprite-list entities)


   (filter identity
           (flatten
           (for/list ([e (in-list (reverse entities))])
             (define ass (get-components e animated-sprite?))

             (for/list ([as (in-list ass)])
               (if (get-component e hidden?)
                   #f
                   (animated-sprite->ml:sprite e as)))))))


(define (animated-sprite->ml:sprite e as)

  ;(define (ui? e)
  ;  (and (get-component e layer?)
  ;       (eq? (get-layer e) "ui")))

  ;(define (tops? e)  ; for treetops and rooftops
  ;  (and (get-component e layer?)
  ;       (eq? (get-layer e) "tops")))
  (define (mode7-floor? e)
    (and (get-component e layer?)
         (eq? (get-layer e) "mode7-floor")))

  (define layer (if (get-sprite-layer as)
                    (cond [(eq? (get-sprite-layer as) "star-wars") 5]
                          [(eq? (get-sprite-layer as) "ui")   4]
                          [(eq? (get-sprite-layer as) "sky")  3]
                          [(eq? (get-sprite-layer as) "tops") 2]
                          [(eq? (get-sprite-layer as) "mode7-floor") 0]
                          [else      1])
                    (cond [(star-wars-layer? e) 5]
                          [(ui? e)   4]
                          [(sky-layer? e)  3]
                          [(tops? e) 2]
                          [(mode7-floor? e) 0]
                          [else      1])))

  
  (cond [(image-animated-sprite? as) (image-animated-sprite->ml:sprite e as layer)]
        [(string-animated-sprite? as) (string-animated-sprite->ml:sprite e as layer)]
        [else (error "What was that?")]))

;size face family style weight
(define (font-eq? f1 f2)
    (define f1-size   (send f1 get-size))
    (define f1-face   (send f1 get-face))
    (define f1-family (send f1 get-family))
    (define f1-style  (send f1 get-style))
    (define f1-weight (send f1 get-weight))

    
    (define f2-size   (font-size f2))
    (define f2-face   (font-face f2))
    (define f2-family (font-family f2))
    (define f2-style  (font-style f2))
    (define f2-weight (font-weight f2))
    
    (and (= f1-size f2-size)
         (equal? f1-face f2-face)
         (eq? f1-family f2-family)
         (eq? f1-style f2-style)
         (eq? f1-weight f2-weight)
         ))

(define (string-animated-sprite->ml:sprite e as layer)
  (define get-backing-scale (dynamic-require 'racket/gui/base 'get-display-backing-scale))
  (define tf-scale (text-frame-scale (render-text-frame as)))
  (define tf-font (text-frame-font (render-text-frame as)))
  (define tf-font-size (get-font-size (render-text-frame as)))
    
  (define debug-text-renderer
    (font-renderer
     (or (and tf-font
              (findf (curry font-eq? tf-font) game-fonts))
         (first game-fonts))))
  
  (and debug-text-renderer
       (let ([c (animated-sprite-rgb as)]
             [tf (render-text-frame as)]) ;Get color here, pass to #:r ... etc
         (debug-text-renderer (render-string as)
                              #:r (first c) #:g (second c) #:b (third c)
                              #:layer layer
                              (real->double-flonum
                               (* (get-backing-scale)
                                  (+ (x e)
                                     (animated-sprite-x-offset as))))
                              (real->double-flonum
                               (* (get-backing-scale)
                                  (+ (y e)
                                     (- (* tf-font-size .75)) ;-10
                                     (animated-sprite-y-offset as))))
                              #:mx (real->double-flonum (* (animated-sprite-x-scale as) tf-scale (get-backing-scale)))
                              #:my (real->double-flonum (* (animated-sprite-y-scale as) tf-scale (get-backing-scale))))))
  
  )

(define (image-animated-sprite->ml:sprite e as layer)
  (define get-backing-scale (dynamic-require 'racket/gui/base 'get-display-backing-scale))
  (define c (animated-sprite-rgb as))
  (define f   (current-fast-frame as))

  (define id-sym    (fast-image->id f))

             
  (define sprite-id (ml:sprite-idx csd id-sym))

  (and sprite-id
       (ml:sprite #:layer layer
                  #:r (first c) #:g (second c) #:b (third c)
                  (real->double-flonum
                   (* (get-backing-scale)
                      (+ (x e)
                         (animated-sprite-x-offset as))))
                  (real->double-flonum
                   (* (get-backing-scale)
                      (+ (y e)
                         (animated-sprite-y-offset as))))
                  sprite-id
                  #:mx (real->double-flonum (* (get-backing-scale) (animated-sprite-x-scale as)))
                  #:my (real->double-flonum (* (get-backing-scale) (animated-sprite-y-scale as)))
                  #:theta (real->double-flonum (animated-sprite-rotation as))	 	 
                  ))


  )


