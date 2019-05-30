(ns status-im.tribute-to-talk.core
  (:refer-clojure :exclude [remove])
  (:require [clojure.string :as string]
            [re-frame.core :as re-frame]
            [status-im.accounts.update.core :as accounts.update]
            [status-im.contact.core :as contact]
            [status-im.contact.db :as contact.db]
            [status-im.ethereum.contracts :as contracts]
            [status-im.ethereum.core :as ethereum]
            [status-im.ethereum.json-rpc :as json-rpc]
            [status-im.ethereum.tokens :as tokens]
            [status-im.ethereum.transactions.core :as transactions]
            [status-im.tribute-to-talk.db :as tribute-to-talk.db]
            [status-im.tribute-to-talk.whitelist :as whitelist]
            [status-im.ui.screens.navigation :as navigation]
            [status-im.utils.fx :as fx]
            [status-im.utils.money :as money]
            [status-im.wallet.core :as wallet]
            [status-im.wallet.db :as wallet.db]
            [taoensso.timbre :as log]))

(defn tribute-paid?
  [contact]
  (contains? (:system-tags contact) :tribute-to-talk/paid))

(defn tribute-received?
  [contact]
  (contains? (:system-tags contact) :tribute-to-talk/received))

(defn add-transaction-hash
  [message db]
  (let [to (get-in message [:content :chat-id])
        tribute-transaction-hash
        (get-in db [:contacts/contacts to :tribute-to-talk :transaction-hash])]
    (if tribute-transaction-hash
      (assoc-in message
                [:content :tribute-transaction]
                tribute-transaction-hash)
      message)))

(fx/defn update-settings
  [{:keys [db] :as cofx} {:keys [snt-amount message update] :as new-settings}]
  (let [account-settings (get-in db [:account/account :settings])
        chain-keyword    (ethereum/chain-keyword db)
        tribute-to-talk-settings (cond-> (merge (tribute-to-talk.db/get-settings db)
                                                new-settings)
                                   new-settings
                                   (assoc :seen? true)

                                   (not new-settings)
                                   (dissoc :snt-amount :manifest)

                                   (and (contains? new-settings :update)
                                        (nil? update))
                                   (dissoc :update))]
    (fx/merge cofx
              (accounts.update/update-settings
               (-> account-settings
                   (assoc-in [:tribute-to-talk chain-keyword]
                             tribute-to-talk-settings))
               {})
              (whitelist/enable-whitelist))))

(fx/defn mark-ttt-as-seen
  [{:keys [db] :as cofx}]
  (when-not (:seen (tribute-to-talk.db/get-settings db))
    (update-settings cofx {:seen? true})))

(fx/defn open-settings
  {:events [:tribute-to-talk.ui/menu-item-pressed]}
  [{:keys [db] :as cofx}]
  (let [settings (tribute-to-talk.db/get-settings db)
        updated-settings (:update settings)]
    (fx/merge cofx
              mark-ttt-as-seen
              (navigation/navigate-to-cofx
               :tribute-to-talk
               (cond
                 updated-settings
                 (merge {:step :finish}
                        updated-settings
                        (when updated-settings
                          {:state :pending}))
                 (:snt-amount settings)
                 (merge {:step :edit
                         :editing? true}
                        (update settings :snt-amount tribute-to-talk.db/from-wei))
                 :else
                 {:step :intro})))))

(fx/defn set-step
  [{:keys [db]} step]
  {:db (assoc-in db [:navigation/screen-params :tribute-to-talk :step] step)})

(fx/defn set-tribute-signing-flow
  [{:keys [db] :as cofx} tribute]
  (if-let [contract (contracts/get-address db :status/tribute-to-talk)]
    (wallet/eth-transaction-call
     cofx
     {:contract contract
      :method "setRequiredTribute(uint256)"
      :params [tribute]
      :on-result [:tribute-to-talk.callback/set-tribute-transaction-sent]
      :on-error [:tribute-to-talk.callback/set-tribute-transaction-failed]})
    {:db (assoc-in db
                   [:navigation/screen-params :tribute-to-talk :state]
                   :transaction-failed)}))

(fx/defn remove
  {:events [:tribute-to-talk.ui/remove-pressed]}
  [{:keys [db] :as cofx}]
  (if-let [contract (contracts/get-address db :status/tribute-to-talk)]
    (fx/merge cofx
              {:db (assoc-in db [:navigation/screen-params :tribute-to-talk]
                             {:step :finish
                              :state :disabled})}
              (wallet/eth-transaction-call
               {:contract contract
                :method "reset()"
                :on-result
                [:tribute-to-talk.callback/set-tribute-transaction-sent]
                :on-error
                [:tribute-to-talk.callback/set-tribute-transaction-failed]}))
    {:db (assoc-in db
                   [:navigation/screen-params :tribute-to-talk :state]
                   :transaction-failed)}))

(fx/defn set-step-finish
  [{:keys [db] :as cofx}]
  (let [tribute (get-in db [:navigation/screen-params :tribute-to-talk :snt-amount])]
    (fx/merge cofx
              {:db (assoc-in db [:navigation/screen-params :tribute-to-talk :state] :signing)}
              (set-tribute-signing-flow (tribute-to-talk.db/to-wei tribute))
              (set-step :finish))))

(fx/defn open-learn-more
  {:events [:tribute-to-talk.ui/learn-more-pressed]}
  [cofx]
  (set-step cofx :learn-more))

(fx/defn step-back
  {:events [:tribute-to-talk.ui/step-back-pressed]}
  [cofx]
  (let [{:keys [step editing?]}
        (get-in cofx [:db :navigation/screen-params :tribute-to-talk])]
    (case step
      (:intro :edit)
      (navigation/navigate-back cofx)

      (:learn-more :set-snt-amount)
      (set-step cofx (if editing?
                       :edit
                       :intro))

      :finish
      (set-step cofx :set-snt-amount))))

(fx/defn step-forward
  {:events [:tribute-to-talk.ui/step-forward-pressed]}
  [cofx]
  (let [{:keys [step editing?]}
        (get-in cofx [:db :navigation/screen-params :tribute-to-talk])]
    (case step
      :intro
      (set-step cofx :set-snt-amount)

      :set-snt-amount
      (set-step-finish cofx)

      :finish
      (navigation/navigate-back cofx))))

(defn get-new-snt-amount
  [snt-amount numpad-symbol]
  ;; TODO: Put some logic in place so that incorrect numbers can not
  ;; be entered
  (let [snt-amount  (or (str snt-amount) "0")]
    (if (= numpad-symbol :remove)
      (let [len (count snt-amount)
            s (subs snt-amount 0 (dec len))]
        (cond-> s
          ;; Remove both the digit after the dot and the dot itself
          (string/ends-with? s ".") (subs 0 (- len 2))
          ;; Set default value if last digit is removed
          (string/blank? s) (do "0")))
      (cond
        ;; Disallow two consecutive dots
        (and (string/includes? snt-amount ".") (= numpad-symbol "."))
        snt-amount
        ;; Disallow more than 2 digits after the dot
        (and (string/includes? snt-amount ".")
             (> (count (second (string/split snt-amount #"\."))) 1))
        snt-amount
        ;; Disallow values larger than 1 million
        (and (not (string/includes? snt-amount "."))
             (not= numpad-symbol ".")
             (>= (js/parseInt (str snt-amount numpad-symbol)) tribute-to-talk.db/max-snt-amount))
        snt-amount
        ;; Replace initial "0" by the first digit
        (and (= snt-amount "0") (not= numpad-symbol "."))
        (str numpad-symbol)
        :else (str snt-amount numpad-symbol)))))

(fx/defn update-snt-amount
  {:events [:tribute-to-talk.ui/numpad-key-pressed]}
  [{:keys [db]} numpad-symbol]
  {:db (update-in db
                  [:navigation/screen-params :tribute-to-talk :snt-amount]
                  #(get-new-snt-amount % numpad-symbol))})

(fx/defn start-editing
  {:events [:tribute-to-talk.ui/edit-pressed]}
  [{:keys [db]}]
  {:db (assoc-in db
                 [:navigation/screen-params :tribute-to-talk :step]
                 :set-snt-amount)})

(fx/defn on-check-tribute-success
  {:events [:tribute-to-talk.callback/check-tribute-success]}
  [cofx public-key tribute-to-talk]
  (let [tribute-to-talk (when (tribute-to-talk.db/valid? tribute-to-talk)
                          tribute-to-talk)]
    (if-let [me? (= public-key
                    (get-in cofx [:db :account/account :public-key]))]
      (update-settings cofx tribute-to-talk)
      (contact/set-tribute cofx public-key tribute-to-talk))))

(fx/defn on-no-tribute-found
  {:events [:tribute-to-talk.callback/no-tribute-found]}
  [cofx public-key]
  (if-let [me? (= public-key
                  (get-in cofx [:db :account/account :public-key]))]
    (update-settings cofx nil)
    (contact/set-tribute cofx public-key nil)))

(re-frame/reg-fx
 :tribute-to-talk/get-tribute
 (fn [{:keys [contract address on-success]}]
   (json-rpc/eth-call
    {:contract contract
     :method "getFee(address)"
     :params [address]
     :outputs ["uint256"]
     :on-success on-success})))

(fx/defn check-tribute
  [{:keys [db] :as cofx} public-key]
  (when (and (not (get-in db [:chats public-key :group-chat]))
             (not (get-in db [:contacts/contacts public-key :tribute-to-talk
                              :transaction-hash]))
             (not (tribute-to-talk.db/whitelisted?
                   (get-in db [:contacts/contacts public-key]))))
    (if-let [contract (contracts/get-address db :status/tribute-to-talk)]
      (let [address (ethereum/public-key->address public-key)]
        {:tribute-to-talk/get-tribute
         {:contract contract
          :address  address
          :on-success
          (fn [[tribute]]
            (re-frame/dispatch
             (if tribute
               [:tribute-to-talk.callback/check-tribute-success
                public-key
                {:snt-amount (str tribute)}]
               [:tribute-to-talk.callback/no-tribute-found public-key])))}})
        ;; update settings if checking own manifest or do nothing otherwise
      (if-let [me? (= public-key
                      (get-in cofx [:db :account/account :public-key]))]

        (fx/merge cofx
                  {:db (assoc-in db
                                 [:navigation/screen-params :tribute-to-talk :unavailable?]
                                 true)}
                  (update-settings nil))
        (contact/set-tribute cofx public-key nil)))))

(fx/defn check-own-tribute
  [cofx]
  (check-tribute cofx (get-in cofx [:db :account/account :public-key])))

(defn- transaction-details
  [contact symbol]
  (-> contact
      (select-keys [:name :address :public-key])
      (assoc :symbol symbol
             :gas (ethereum/estimate-gas symbol)
             :from-chat? true)))

(fx/defn pay-tribute
  {:events [:tribute-to-talk.ui/on-pay-to-chat-pressed]}
  [{:keys [db] :as cofx} public-key]
  (let [{:keys [name address public-key tribute-to-talk] :as recipient-contact}
        (get-in db [:contacts/contacts public-key])
        {:keys [snt-amount]} tribute-to-talk
        chain                (ethereum/chain-keyword db)
        symbol               (case chain
                               :mainnet :SNT
                               :STT)
        all-tokens           (:wallet/all-tokens db)
        wallet-balance       (get-in db [:wallet :balance symbol])
        {:keys [decimals]}   (tokens/asset-for all-tokens chain symbol)
        amount-text          (str (tribute-to-talk.db/from-wei snt-amount))
        {:keys [value]}      (wallet.db/parse-amount amount-text decimals)
        internal-value       (money/formatted->internal value symbol decimals)]
    (wallet/eth-transaction-call
     cofx
     {:contract (contracts/get-address db :status/snt)
      :method   "transfer(address,uint256)"
      :params   [address internal-value]
      :details  {:to-name     name
                 :public-key  public-key
                 :from-chat?  true
                 :asset       symbol
                 :amount-text amount-text
                 :sufficient-funds?
                 (money/sufficient-funds? snt-amount wallet-balance)
                 :send-transaction-message? true}
      :on-result [:tribute-to-talk.callback/pay-tribute-transaction-sent
                  public-key]})))

(defn tribute-transaction-trigger
  [db {:keys [block error?]}]
  (let [current-block (get db :ethereum/current-block)
        transaction-block (or block
                              current-block)]
    (or error?
        (pos? (- current-block
                 (js/parseInt transaction-block))))))

(fx/defn on-pay-tribute-transaction-triggered
  [{:keys [db] :as cofx}
   public-key
   {:keys [error? transfer symbol] :as transaction}]
  (when (and transfer
             (= symbol (case (ethereum/chain-keyword db)
                         :mainnet :SNT
                         :STT))
             (not error?))
    (whitelist/mark-tribute-paid cofx public-key)))

(fx/defn on-pay-tribute-transaction-sent
  {:events [:tribute-to-talk.callback/pay-tribute-transaction-sent]}
  [{:keys [db] :as cofx} public-key id transaction-hash method]
  (fx/merge cofx
            {:db (assoc-in db [:contacts/contacts public-key
                               :tribute-to-talk :transaction-hash]
                           transaction-hash)}
            (navigation/navigate-to-clean :wallet-transaction-sent-modal {})
            (transactions/watch-transaction
             transaction-hash
             {:trigger-fn
              tribute-transaction-trigger
              :on-trigger
              #(on-pay-tribute-transaction-triggered public-key %)})))

(fx/defn on-set-tribute-transaction-triggered
  [{:keys [db] :as cofx} {:keys [error?] :as transaction}]
  (if error?
    (fx/merge cofx
              {:db (assoc-in db [:navigation/screen-params
                                 :tribute-to-talk :state]
                             :transaction-failed)}
              (update-settings {:update nil}))
    (fx/merge cofx
              {:db (assoc-in db [:navigation/screen-params
                                 :tribute-to-talk :state]
                             :completed)}
              (check-own-tribute)
              (update-settings {:update nil}))))

(fx/defn on-set-tribute-transaction-sent
  {:events [:tribute-to-talk.callback/set-tribute-transaction-sent]}
  [{:keys [db] :as cofx} id transaction-hash method]
  (let [{:keys [snt-amount message]} (get-in db [:navigation/screen-params
                                                 :tribute-to-talk])]
    (fx/merge cofx
              {:db (assoc-in db [:navigation/screen-params
                                 :tribute-to-talk :state]
                             :pending)}
              (navigation/navigate-to-clean :wallet-transaction-sent-modal {})
              (update-settings {:update {:transaction transaction-hash
                                         :snt-amount  snt-amount
                                         :message     message}})
              (transactions/watch-transaction
               transaction-hash
               {:trigger-fn
                tribute-transaction-trigger
                :on-trigger
                on-set-tribute-transaction-triggered}))))

(fx/defn on-set-tribute-transaction-failed
  {:events [:tribute-to-talk.callback/set-tribute-transaction-failed]}
  [{:keys [db] :as cofx} error]
  (log/error :set-tribute-transaction-failed error)
  {:db (assoc-in db
                 [:navigation/screen-params :tribute-to-talk :state]
                 :transaction-failed)})

(fx/defn watch-set-tribute-transaction
  "check if there is a pending transaction to set the tribute and
   add a watch on that transaction
   if there is a transaction check if the trigger is valid already"
  [{:keys [db] :as cofx}]
  (when-let [transaction-hash
             (get-in (tribute-to-talk.db/get-settings db)
                     [:update :transaction])]
    (let [transaction (get-in db [:wallet :transactions transaction-hash])]
      (fx/merge cofx
                (transactions/watch-transaction
                 transaction-hash
                 {:trigger-fn
                  tribute-transaction-trigger
                  :on-trigger
                  on-set-tribute-transaction-triggered})
                (when transaction
                  (transactions/check-transaction transaction))))))

(fx/defn init
  [cofx]
  (fx/merge cofx
            (check-own-tribute)
            (watch-set-tribute-transaction)))
