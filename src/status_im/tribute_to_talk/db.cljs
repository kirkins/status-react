(ns status-im.tribute-to-talk.db
  (:require [status-im.ethereum.core :as ethereum]
            [status-im.i18n :as i18n]
            [status-im.js-dependencies :as dependencies]))

(def max-snt-amount 1000000)

(defn utils [] (dependencies/web3-utils))

(defn to-wei
  [s]
  (when s
    (.toWei (utils) s)))

(defn from-wei
  [s]
  (when s
    (.fromWei (utils) s)))

(defn tribute-status
  [{:keys [system-tags tribute-to-talk] :as contact}]
  (let [{:keys [snt-amount transaction-hash]} tribute-to-talk]
    (cond (contains? system-tags :tribute-to-talk/paid) :paid
          (not (nil? transaction-hash)) :pending
          (pos? snt-amount) :required
          :else :none)))

(defn status-label
  [tribute-status tribute]
  (case tribute-status
    :paid (i18n/label :t/tribute-state-paid)
    :pending (i18n/label :t/tribute-state-pending)
    :required (i18n/label :t/tribute-state-required
                          {:snt-amount (from-wei tribute)})
    nil))

(defn valid?
  [{:keys [snt-amount]}]
  (when (string? snt-amount)
    (try (let [converted-snt-amount (from-wei snt-amount)]
           (and (= (to-wei converted-snt-amount)
                   snt-amount)
                (< (js/parseFloat converted-snt-amount) max-snt-amount)))
         (catch :default err nil))))

(defn get-settings
  [db]
  (let [chain-keyword (ethereum/chain-keyword db)]
    (get-in db [:account/account :settings :tribute-to-talk chain-keyword])))

(defn enabled?
  [settings]
  (:snt-amount settings))

(defn- valid-tribute-tx?
  [db snt-amount tribute-transaction from-public-key]
  (let [{:keys [value confirmations from] :as transaction}
        (get-in db [:wallet :transactions tribute-transaction])]
    (and transaction
         (pos? (js/parseInt (or confirmations "0")))
         (<= snt-amount value)
         (= (ethereum/address= (ethereum/public-key->address from-public-key)
                               from)))))

(defn whitelisted-by? [{:keys [system-tags]}]
  (or (contains? system-tags :contact/request-received)
      (contains? system-tags :tribute-to-talk/paid)
      (contains? system-tags :tribute-to-talk/received)))

(defn whitelisted? [{:keys [system-tags]}]
  (or (contains? system-tags :contact/added)
      (contains? system-tags :tribute-to-talk/paid)
      (contains? system-tags :tribute-to-talk/received)))

(defn get-contact-whitelist
  [contacts]
  (reduce (fn [acc {:keys [public-key] :as contact}]
            (if (whitelisted? contact)
              (conj acc public-key) acc))
          (hash-set) contacts))
