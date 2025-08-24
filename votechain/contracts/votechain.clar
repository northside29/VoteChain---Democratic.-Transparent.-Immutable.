;; VoteChain - Democratic. Transparent. Immutable.
;; A decentralized voting platform for community governance
;; Features: Proposal creation, secure voting, transparent results

;; ===================================
;; CONSTANTS AND ERROR CODES
;; ===================================

(define-constant ERR-NOT-AUTHORIZED (err u100))
(define-constant ERR-PROPOSAL-NOT-FOUND (err u101))
(define-constant ERR-VOTING-CLOSED (err u102))
(define-constant ERR-ALREADY-VOTED (err u103))
(define-constant ERR-INVALID-OPTION (err u104))
(define-constant ERR-VOTING-ACTIVE (err u105))

;; Contract constants
(define-constant CONTRACT-OWNER tx-sender)
(define-constant MIN-VOTING-PERIOD u144) ;; ~1 day minimum
(define-constant MAX-VOTING_PERIOD u1440) ;; ~10 days maximum

;; ===================================
;; DATA VARIABLES
;; ===================================

(define-data-var platform-active bool true)
(define-data-var proposal-counter uint u0)
(define-data-var total-votes-cast uint u0)

;; ===================================
;; TOKEN DEFINITIONS
;; ===================================

;; Voting tokens for weighted voting
(define-fungible-token vote-token)

;; ===================================
;; DATA MAPS
;; ===================================

;; Proposals
(define-map proposals
  uint
  {
    title: (string-ascii 64),
    description: (string-ascii 256),
    creator: principal,
    start-block: uint,
    end-block: uint,
    total-votes: uint,
    yes-votes: uint,
    no-votes: uint,
    active: bool
  }
)

;; User votes per proposal
(define-map user-votes
  { proposal-id: uint, voter: principal }
  {
    vote-choice: bool,
    vote-weight: uint,
    timestamp: uint
  }
)

;; User voting statistics
(define-map voter-stats
  principal
  {
    proposals-voted: uint,
    total-vote-weight: uint,
    last-activity: uint
  }
)

;; ===================================
;; PRIVATE HELPER FUNCTIONS
;; ===================================

(define-private (is-contract-owner (user principal))
  (is-eq user CONTRACT-OWNER)
)

(define-private (is-voting-active (proposal-id uint))
  (match (map-get? proposals proposal-id)
    proposal-data
    (and 
      (get active proposal-data)
      (>= burn-block-height (get start-block proposal-data))
      (< burn-block-height (get end-block proposal-data))
    )
    false
  )
)

(define-private (has-user-voted (proposal-id uint) (user principal))
  (is-some (map-get? user-votes { proposal-id: proposal-id, voter: user }))
)

;; ===================================
;; READ-ONLY FUNCTIONS
;; ===================================

(define-read-only (get-platform-info)
  {
    active: (var-get platform-active),
    total-proposals: (var-get proposal-counter),
    total-votes: (var-get total-votes-cast)
  }
)

(define-read-only (get-proposal (proposal-id uint))
  (map-get? proposals proposal-id)
)

(define-read-only (get-user-vote (proposal-id uint) (voter principal))
  (map-get? user-votes { proposal-id: proposal-id, voter: voter })
)

(define-read-only (get-voter-stats (voter principal))
  (map-get? voter-stats voter)
)

(define-read-only (get-proposal-results (proposal-id uint))
  (match (map-get? proposals proposal-id)
    proposal-data
    (some {
      total-votes: (get total-votes proposal-data),
      yes-votes: (get yes-votes proposal-data),
      no-votes: (get no-votes proposal-data),
      yes-percentage: (if (> (get total-votes proposal-data) u0)
                        (/ (* (get yes-votes proposal-data) u100) (get total-votes proposal-data))
                        u0),
      passed: (> (get yes-votes proposal-data) (get no-votes proposal-data))
    })
    none
  )
)

(define-read-only (get-voting-status (proposal-id uint))
  (match (map-get? proposals proposal-id)
    proposal-data
    (if (< burn-block-height (get start-block proposal-data))
      (some "pending")
      (if (is-voting-active proposal-id)
        (some "active")
        (if (>= burn-block-height (get end-block proposal-data))
          (some "ended")
          (some "inactive")
        )
      )
    )
    none
  )
)

;; ===================================
;; ADMIN FUNCTIONS
;; ===================================

(define-public (toggle-platform (active bool))
  (begin
    (asserts! (is-contract-owner tx-sender) ERR-NOT-AUTHORIZED)
    (var-set platform-active active)
    (print { action: "platform-toggled", active: active })
    (ok true)
  )
)

(define-public (mint-vote-tokens (amount uint) (recipient principal))
  (begin
    (asserts! (is-contract-owner tx-sender) ERR-NOT-AUTHORIZED)
    (asserts! (> amount u0) ERR-INVALID-OPTION)
    (try! (ft-mint? vote-token amount recipient))
    (print { action: "vote-tokens-minted", amount: amount, recipient: recipient })
    (ok true)
  )
)

;; ===================================
;; PROPOSAL FUNCTIONS
;; ===================================

(define-public (create-proposal 
  (title (string-ascii 64))
  (description (string-ascii 256))
  (voting-duration uint)
)
  (let (
    (proposal-id (+ (var-get proposal-counter) u1))
    (start-block (+ burn-block-height u1))
    (end-block (+ start-block voting-duration))
  )
    (asserts! (var-get platform-active) ERR-NOT-AUTHORIZED)
    (asserts! (>= voting-duration MIN-VOTING-PERIOD) ERR-INVALID-OPTION)
    (asserts! (<= voting-duration MAX-VOTING_PERIOD) ERR-INVALID-OPTION)
    
    ;; Create proposal
    (map-set proposals proposal-id {
      title: title,
      description: description,
      creator: tx-sender,
      start-block: start-block,
      end-block: end-block,
      total-votes: u0,
      yes-votes: u0,
      no-votes: u0,
      active: true
    })
    
    (var-set proposal-counter proposal-id)
    (print { action: "proposal-created", proposal-id: proposal-id, creator: tx-sender, title: title })
    (ok proposal-id)
  )
)

(define-public (cancel-proposal (proposal-id uint))
  (let (
    (proposal-data (unwrap! (map-get? proposals proposal-id) ERR-PROPOSAL-NOT-FOUND))
  )
    (asserts! (is-eq tx-sender (get creator proposal-data)) ERR-NOT-AUTHORIZED)
    (asserts! (get active proposal-data) ERR-VOTING-CLOSED)
    (asserts! (< burn-block-height (get start-block proposal-data)) ERR-VOTING-ACTIVE)
    
    (map-set proposals proposal-id (merge proposal-data { active: false }))
    (print { action: "proposal-cancelled", proposal-id: proposal-id })
    (ok true)
  )
)

;; ===================================
;; VOTING FUNCTIONS
;; ===================================

(define-public (vote-yes (proposal-id uint))
  (let (
    (proposal-data (unwrap! (map-get? proposals proposal-id) ERR-PROPOSAL-NOT-FOUND))
    (vote-weight (ft-get-balance vote-token tx-sender))
    (voter-statistics (default-to { proposals-voted: u0, total-vote-weight: u0, last-activity: u0 }
                                  (map-get? voter-stats tx-sender)))
  )
    (asserts! (var-get platform-active) ERR-NOT-AUTHORIZED)
    (asserts! (is-voting-active proposal-id) ERR-VOTING-CLOSED)
    (asserts! (not (has-user-voted proposal-id tx-sender)) ERR-ALREADY-VOTED)
    (asserts! (> vote-weight u0) ERR-INVALID-OPTION)
    
    ;; Record vote
    (map-set user-votes { proposal-id: proposal-id, voter: tx-sender } {
      vote-choice: true,
      vote-weight: vote-weight,
      timestamp: burn-block-height
    })
    
    ;; Update proposal totals
    (map-set proposals proposal-id (merge proposal-data {
      total-votes: (+ (get total-votes proposal-data) vote-weight),
      yes-votes: (+ (get yes-votes proposal-data) vote-weight)
    }))
    
    ;; Update voter stats
    (map-set voter-stats tx-sender (merge voter-statistics {
      proposals-voted: (+ (get proposals-voted voter-statistics) u1),
      total-vote-weight: (+ (get total-vote-weight voter-statistics) vote-weight),
      last-activity: burn-block-height
    }))
    
    ;; Update global stats
    (var-set total-votes-cast (+ (var-get total-votes-cast) u1))
    
    (print { action: "vote-cast", proposal-id: proposal-id, voter: tx-sender, choice: "yes", weight: vote-weight })
    (ok true)
  )
)

(define-public (vote-no (proposal-id uint))
  (let (
    (proposal-data (unwrap! (map-get? proposals proposal-id) ERR-PROPOSAL-NOT-FOUND))
    (vote-weight (ft-get-balance vote-token tx-sender))
    (voter-statistics (default-to { proposals-voted: u0, total-vote-weight: u0, last-activity: u0 }
                                  (map-get? voter-stats tx-sender)))
  )
    (asserts! (var-get platform-active) ERR-NOT-AUTHORIZED)
    (asserts! (is-voting-active proposal-id) ERR-VOTING-CLOSED)
    (asserts! (not (has-user-voted proposal-id tx-sender)) ERR-ALREADY-VOTED)
    (asserts! (> vote-weight u0) ERR-INVALID-OPTION)
    
    ;; Record vote
    (map-set user-votes { proposal-id: proposal-id, voter: tx-sender } {
      vote-choice: false,
      vote-weight: vote-weight,
      timestamp: burn-block-height
    })
    
    ;; Update proposal totals
    (map-set proposals proposal-id (merge proposal-data {
      total-votes: (+ (get total-votes proposal-data) vote-weight),
      no-votes: (+ (get no-votes proposal-data) vote-weight)
    }))
    
    ;; Update voter stats
    (map-set voter-stats tx-sender (merge voter-statistics {
      proposals-voted: (+ (get proposals-voted voter-statistics) u1),
      total-vote-weight: (+ (get total-vote-weight voter-statistics) vote-weight),
      last-activity: burn-block-height
    }))
    
    ;; Update global stats
    (var-set total-votes-cast (+ (var-get total-votes-cast) u1))
    
    (print { action: "vote-cast", proposal-id: proposal-id, voter: tx-sender, choice: "no", weight: vote-weight })
    (ok true)
  )
)

;; ===================================
;; INITIALIZATION
;; ===================================

(begin
  (print { action: "votechain-initialized", owner: CONTRACT-OWNER })
)