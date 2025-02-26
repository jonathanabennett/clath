(in-package :clath)

(defparameter *callback-extension* "callback/")
(defparameter *login-extension* "login/")
;;Because north supports oauth 1.0a
(defparameter *callback-extension-north* "callback1a/")
(defparameter *login-extension-north* "login1a/")
(defvar *server-url*)

(defparameter *clath-version* "0.1")

(defun user-agent (provider)
  "Some providers, such as Reddit, want a fairly unique user-agent."
  (declare (ignore provider)) ;For now
  (format nil "Clath/~a by BnMcGn" *clath-version*))

(setf drakma:*text-content-types*
      (cons '("application" . "json") drakma:*text-content-types*))

(defun discover-endpoints (discovery-url)
  (let ((disc (cl-json:decode-json-from-string (drakma:http-request discovery-url))))
    (list
     :auth-endpoint (assoc-cdr :authorization--endpoint disc)
     :token-endpoint (assoc-cdr :token--endpoint disc)
     :userinfo-endpoint (assoc-cdr :userinfo--endpoint disc)
     :jwks-uri (assoc-cdr :jwks--uri disc))))

(defun get-jwk-key (jsonkey)
  (let ((kty (cdr (assoc :kty jsonkey))))
    (cond
      ((equal kty "RSA")
       (let ((n (ironclad:octets-to-integer
                 (jose/base64:base64url-decode (cdr (assoc :n jsonkey)))))
             (e (ironclad:octets-to-integer
                 (jose/base64:base64url-decode (cdr (assoc :e jsonkey))))))
         (ironclad:make-public-key :rsa :e e :n n)))
      (t
       (warn "Key type not found.")
       nil))))

(defun fetch-jwks (jwks-uri)
  (let* ((data (cl-json:decode-json-from-string (drakma:http-request jwks-uri)))
         (res nil)
         (algs nil)
         (alglist '(:hs256 :hs384 :hs512 :rs256 :rs384 :rs512 :ps256 :ps384 :ps512)))
    (dolist (key (cdr (assoc :keys data)))
      (when-let ((kobj (get-jwk-key key))
                 (alg (find (cdr (assoc :alg key)) alglist :test #'string-equal)))
        (push (cons (cdr (assoc :kid key)) kobj) res)
        (push (cons (cdr (assoc :kid key)) alg) algs)))
    (values (nreverse res) (nreverse algs))))

(defun update-jwks (provider jwks-uri)
  (multiple-value-bind (keys algs) (fetch-jwks jwks-uri)
    (setf (getf (getf *provider-info* provider) :keys) keys)
    (setf (getf (getf *provider-info* provider) :algorithms) algs)))

(defun get-jwk (kid provider)
  (when-let ((key (assoc kid (getf (getf *provider-info* provider) :keys) :test #'equal)))
    (cdr key)))

(defun ensure-jwk (kid provider)
  (or (get-jwk kid provider)
      (progn
        ;;Try again. Maybe there is an update...
        (update-jwks provider (getf (getf *provider-info* provider) :jwks-uri))
        (or (get-jwk kid provider)
            (error "Can't find the required signing key from OpenID Connect provider")))))

(defun unpack-and-check-jwt (jwt provider)
  (multiple-value-bind (tokinfo keyinfo _) (jose:inspect-token jwt)
    (declare (ignore _))
    (let* ((kid (cdr (assoc "kid" keyinfo :test #'equal)))
           (key (ensure-jwk kid provider))
           (alg (cdr (assoc kid (getf (getf *provider-info* provider) :algorithms) :test #'equal))))
      (if (jose:verify alg key jwt)
          tokinfo
          (error "Signature check failed on supplied JWT")))))

;;;FIXME: Endpoint discovery only done on startup. Should look at spec and see if it should
;;;happen more frequently.
(defun provider-info (provider)
  (let ((prov (getf *provider-info* provider)))
    (unless prov (error "Not a recognized provider"))
    (if (getf prov :auth-endpoint)
        (alist-plist
         (extract-keywords
          '(:auth-endpoint :token-endpoint :userinfo-endpoint :auth-scope
            :token-processor :access-endpoint :request-endpoint :jwks-uri)
          prov))
        (progn
          (unless (getf prov :endpoints-url)
            (error "Provider must have :endpoints-url or endpoint definitions"))
          (let ((res (discover-endpoints (getf prov :endpoints-url))))
             (setf (getf *provider-info* provider)
                   (concatenate 'list prov res)))))))

(defun provider-secrets (provider)
  (getf *provider-secrets* provider))

(defun provider-string (provider)
  (if-let ((string (getf (getf *provider-info* provider) :string)))
       string
       (string-downcase (string provider))))

(defun provider-url-string (provider)
  (if-let ((string (getf (getf *provider-info* provider) :url-string)))
    string
    (provider-string provider)))

(defun uses-north-p (provider)
  (getf (getf *provider-info* provider) :use-north))

(defun basic-authorization (provider)
  (let ((secrets (provider-secrets provider)))
    (list (getf secrets :client-id) (getf secrets :secret))))

(defun make-login-url (provider)
  (concatenate
   'string *server-url*
   (if (uses-north-p provider) *login-extension-north* *login-extension*)
   (provider-string provider)))

(defun make-callback-url (provider)
  (concatenate
   'string *server-url*
   (if (uses-north-p provider) *callback-extension-north* *callback-extension*)
   (provider-url-string provider)))

(defun available-providers ()
  (remove-if-not #'keywordp *provider-secrets*))

;;;FIXME: Audit me: this number is probably correct/random enough, because the public
;;;*probably* never sees it. Should get a knowledgable opionion on it though.
(defun gen-state (len)
  (with-output-to-string (stream)
    (let ((*print-base* 36))
      (loop repeat len
         do (princ (random 36) stream)))))

(defun special-url-p (url-path)
  (or (sequence-starts-with (concatenate 'string "/" *callback-extension*) url-path)
      (sequence-starts-with (concatenate 'string "/" *login-extension*) url-path)))

(defun request-user-auth-destination
    (&key auth-scope client-id auth-endpoint state redirect-uri &allow-other-keys)
  (drakma:http-request
   auth-endpoint :redirect nil
   :parameters `(("client_id" . ,client-id) ("app_id" . ,client-id)
                 ("response_type" . "code") ("scope" . ,auth-scope)
                 ("redirect_uri" . ,redirect-uri) ("state" . ,state))))

;;;WARNING: Function saves state to session!
(defun login-action (provider)
  (unless (ningle:context :session)
    (setf (ningle:context :session) (make-hash-table)))
  (let ((state (gen-state 36)))
    (setf (gethash 'state (ningle:context :session)) state)
    (setf (gethash :clath-provider (ningle:context :session)) provider)
    (multiple-value-bind (content resp-code headers uri)
        (apply #'request-user-auth-destination :state state
               :redirect-uri (make-callback-url provider)
               :client-id (getf (provider-secrets provider) :client-id)
               (provider-info provider))
      (declare (ignore headers))
      (if (< resp-code 400) `(302 (:location ,(format nil "~a" uri)))
          content))))

;;;FIXME: Why does this need redirect_uri? Try without.
(defun request-access-token (provider code redirect-uri)
  (let ((info (provider-info provider))
        (secrets (provider-secrets provider)))
    (multiple-value-bind (response code headers)
        (drakma:http-request
         (getf info :token-endpoint)
         :method :post
         :redirect nil
         :user-agent (user-agent provider)
         :basic-authorization (basic-authorization provider)
         :parameters `(("code" . ,code)
                       ("client_id" . ,(getf secrets :client-id))
                       ("app_id" . ,(getf secrets :client-id))
                       ("client_secret" . ,(getf secrets :secret))
                       ("redirect_uri" . ,redirect-uri)
                       ("grant_type" . "authorization_code")))
      (declare (ignore code))
      (let ((subtype (nth-value 1 (drakma:get-content-type headers))))
        (check-for-error
         (cond
           ((equal subtype "json")
            (cl-json:decode-json-from-string response))
           ((equal subtype "x-www-form-urlencoded")
            (quri:url-decode-params
             (flexi-streams:octets-to-string response)))
           ((equal subtype "plain")
            (quri:url-decode-params response))
           (t (error
               "Couldn't find parseable access token"))))))))

(defun get-access-token (atdata)
  (if-let ((atok (assoc :access--token atdata)))
    (cdr atok)
    (cdr (assoc "access_token" atdata :test #'equal))))

(defun get-id-token (atdata provider)
  (if-let ((itok (assoc :id--token atdata)))
    (unpack-and-check-jwt (cdr itok) provider)
    (get-access-token atdata)))

(defun valid-state (received-state)
  (and (ningle:context :session)
       (equal (gethash 'state (ningle:context :session)) received-state)))

;;;FIXME: clath shouldn't be handling destination/redirect. It's a more general
;;; problem. *login-destination* is a temporary hack to deal with that.

(defvar *login-destination* nil)
(defparameter *login-destination-hook* nil)

(defun destination-on-login ()
  (if (functionp *login-destination-hook*)
      (funcall *login-destination-hook*
               :username (gethash :username (ningle:context :session)))
      (if *login-destination* *login-destination*
          (if-let ((dest (gethash :clath-destination
                              (ningle:context :session))))
               dest
               "/"))))

(defun userinfo-get-user-id (provider userinfo)
  (declare (ignore provider)) ;;In future we may specialize
  (cdr (assoc-or '(:sub :id :user--id) userinfo)))

;;FIXME: Could be more generalized
(defun try-request-user-info (provider access-token)
  "Sometimes a newly generated access token won't instantly propagate in the provider's system, so we try a few times to give it a chance."
  (let ((uinfo nil))
    (dotimes (i 10)
      (setf uinfo (request-user-info provider access-token))
      (when (userinfo-get-user-id provider uinfo)
        (return))
      (sleep 1))
    uinfo))

(defun callback-action (provider parameters &optional post-func)
  (cond ((not (valid-state (assoc-cdr "state" parameters #'equal)))
         '(403 '() "Login failed. State mismatch."))
        ((not (assoc-cdr "code" parameters #'equal))
         '(403 '() "Login failed. Didn't receive code parameter from OAuth Server."))
        (t
         (let* ((at-data (request-access-token
                          provider
                          (assoc-cdr "code" parameters #'equal)
                          (make-callback-url provider)))
                (access-token (get-access-token at-data)))
           (when (assoc :error at-data)
             (error (format nil "Error message from OAuth server: ~a"
                            (assoc-cdr :message at-data))))
           (with-keys (:clath-access-token :clath-userinfo
                                           :clath-id-token)
               (ningle:context :session)
             (setf clath-access-token access-token
                   clath-userinfo (try-request-user-info provider access-token)
                   clath-id-token (get-id-token at-data provider)))
           (when (functionp post-func) (funcall post-func))
           `(302 (:location ,(destination-on-login)))))))

(defun logout-action ()
  (remhash 'state (ningle:context :session))
  (remhash :clath-provider (ningle:context :session))
  (remhash :clath-access-token (ningle:context :session))
  (remhash :clath-userinfo (ningle:context :session))
  (remhash :clath-id-token (ningle:context :session)))

;;;WARNING: Function saves state to session!
(defun login-action-north (provider)
  (unless (ningle:context :session)
    (setf (ningle:context :session) (make-hash-table)))
  (let* ((provinfo (provider-info provider))
         (nclient
          (make-instance
           'north:client
           :key (getf (provider-secrets provider) :client-id)
           :secret (getf (provider-secrets provider) :secret)
           :authorize-uri (getf provinfo :auth-endpoint)
           :access-token-uri (getf provinfo :access-endpoint)
           :request-token-uri (getf provinfo :request-endpoint)
           :callback (make-callback-url provider))))
    (setf (gethash 'north-client (ningle:context :session)) nclient)
    (setf (gethash :clath-provider (ningle:context :session)) provider)
    `(302 (:location ,(north:initiate-authentication nclient)))))

(defun callback-action-north (provider parameters &optional post-func)
  (let* ((nclient (gethash 'north-client (ningle:context :session)))
         (token (north:token nclient)))
    (cond ((not (equal token (assoc-cdr "oauth_token" parameters #'equal)))
           '(403 '() "Login failed. State mismatch."))
          ((not (assoc-cdr "oauth_verifier" parameters #'equal))
           '(403 '()
             "Login failed. Didn't receive code parameter from OAuth Server."))
          (t
           (north:complete-authentication
            nclient
            (assoc-cdr "oauth_verifier" parameters #'equal))
           (setf (gethash :clath-userinfo (ningle:context :session))
                 (request-user-info-north provider nclient))
           (when (functionp post-func) (funcall post-func))
           `(302 (:location ,(destination-on-login)))))))
