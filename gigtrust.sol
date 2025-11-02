// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title GigTrust
 * @dev A smart contract to manage a trust-based gig economy system using escrow
 * for payment and a one-sided reputation system (Contractor rates Worker).
 * * This contract is the definitive, immutable source of truth for all gig
 * states and handles all ETH transactions securely on the blockchain.
 */
contract GigTrust {
    // --- State Variables and Data Structures ---

    // Define the roles for users
    enum UserRole {
        None,
        Contractor, // Posts gigs, pays, rates workers
        Worker      // Accepts gigs, receives pay
    }

    // Define the lifecycle status of a gig
    enum GigStatus {
        Open,                 // Created by Contractor, awaiting Worker acceptance
        Accepted,             // Accepted by Worker, funds held in escrow
        CompletedByWorker,    // Worker marked the job as done
        ConfirmedByContractor, // Contractor confirmed completion, ready for payment/rating
        Paid,                 // Payment sent to Worker, rating can now occur
        Cancelled             // Gig was cancelled
    }

    // Structure to store user profile and reputation data
    struct User {
        UserRole role;
        uint256 totalRating;    // Sum of all ratings received (1 to 5)
        uint256 reviewCount;    // Total number of reviews received
    }

    // Structure to store gig details
    struct Gig {
        uint256 id;
        address payable contractor; // The party who created the gig and pays
        address payable worker;     // The party who accepts the gig and performs the work
        string description;
        uint256 fee;            // The amount held in escrow for the worker
        GigStatus status;
        // Tracking if the worker has been rated by the contractor
        bool contractorRatedWorker;
    }

    // Mappings to store data
    mapping(address => User) public users;
    mapping(uint256 => Gig) public gigs;
    uint256 public nextGigId = 1; // Counter for unique gig IDs

    // --- Events (Crucial for Backend Integration) ---

    // The traditional backend (server) will monitor these events to update its database.
    event UserRegistered(address indexed userAddress, UserRole role);
    event GigCreated(uint256 indexed gigId, address indexed contractor, uint256 fee);
    event GigAccepted(uint256 indexed gigId, address indexed worker);
    event GigCompleted(uint256 indexed gigId); // ADDED: The missing event declaration
    event GigConfirmed(uint256 indexed gigId);
    event PaymentSent(uint256 indexed gigId, address indexed worker, uint256 amount);
    event UserRated(address indexed rater, address indexed ratedUser, uint256 rating, uint256 newReputationScore);

    // --- Modifiers ---

    modifier onlyRole(UserRole _role) {
        require(users[msg.sender].role == _role, "GigTrust: Caller must have the required role.");
        _;
    }

    modifier onlyGigParticipant(uint256 _gigId) {
        require(msg.sender == gigs[_gigId].contractor || msg.sender == gigs[_gigId].worker, "GigTrust: Caller is not a participant.");
        _;
    }

    // --- Functions ---

    /**
     * @dev Allows a user to register as either a Contractor or a Worker.
     * This function is typically called by the frontend or an authentication service.
     */
    function registerUser(UserRole _role) public {
        require(users[msg.sender].role == UserRole.None, "GigTrust: User already registered.");
        require(_role == UserRole.Contractor || _role == UserRole.Worker, "GigTrust: Invalid role specified.");
        users[msg.sender].role = _role;
        emit UserRegistered(msg.sender, _role);
    }

    /**
     * @dev Contractor creates a new gig and sends the payment to the contract (escrow).
     * The `payable` keyword is essential for receiving the ETH.
     */
    function createGig(string memory _description, uint256 _fee) public payable onlyRole(UserRole.Contractor) {
        require(_fee > 0, "GigTrust: Fee must be greater than zero.");
        // Crucial Escrow check: Ensures the ETH sent matches the declared fee
        require(msg.value == _fee, "GigTrust: Sent value must match the specified fee for escrow.");

        uint256 gigId = nextGigId;
        gigs[gigId] = Gig({
            id: gigId,
            contractor: payable(msg.sender),
            worker: payable(address(0)),
            description: _description,
            fee: _fee,
            status: GigStatus.Open,
            contractorRatedWorker: false
        });

        nextGigId++;
        // Backend monitors this to display the new job on the marketplace
        emit GigCreated(gigId, msg.sender, _fee);
    }

    /**
     * @dev Worker accepts an open gig.
     */
    function acceptGig(uint256 _gigId) public onlyRole(UserRole.Worker) {
        Gig storage gig = gigs[_gigId];
        require(gig.status == GigStatus.Open, "GigTrust: Gig is not open.");
        require(gig.contractor != msg.sender, "GigTrust: Cannot accept your own gig.");

        gig.worker = payable(msg.sender);
        gig.status = GigStatus.Accepted;
        emit GigAccepted(_gigId, msg.sender);
    }

    /**
     * @dev Worker marks the gig as completed.
     */
    function completeGig(uint256 _gigId) public {
        Gig storage gig = gigs[_gigId];
        require(gig.status == GigStatus.Accepted, "GigTrust: Gig must be in Accepted status.");
        require(gig.worker == msg.sender, "GigTrust: Only the assigned worker can complete the gig.");

        gig.status = GigStatus.CompletedByWorker;
        emit GigCompleted(_gigId);
    }

    /**
     * @dev Contractor confirms the gig is complete and pays the worker (releases escrow).
     * This is the core money transfer logic.
     */
    function confirmGigAndPay(uint256 _gigId) public {
        Gig storage gig = gigs[_gigId];
        require(gig.status == GigStatus.CompletedByWorker, "GigTrust: Gig must be completed by worker first.");
        require(gig.contractor == msg.sender, "GigTrust: Only the contractor can confirm the gig.");

        gig.status = GigStatus.ConfirmedByContractor;

        // ETH Transaction: Transfer funds from the contract to the worker
        (bool success, ) = gig.worker.call{value: gig.fee}("");
        require(success, "GigTrust: ETH transfer failed.");

        gig.status = GigStatus.Paid;

        // Backend monitors this event to mark job as finished and update worker's balance display
        emit PaymentSent(_gigId, gig.worker, gig.fee);
    }

    /**
     * @dev Allows only the Contractor to rate the Worker after a gig is paid.
     */
    function rateUser(uint256 _gigId, address _userToRate, uint256 _rating) public onlyGigParticipant(_gigId) {
        Gig storage gig = gigs[_gigId];
        require(gig.status == GigStatus.Paid, "GigTrust: Rating is only allowed after payment.");
        require(_rating >= 1 && _rating <= 5, "GigTrust: Rating must be between 1 and 5.");
        
        bool isContractorRatingWorker = (msg.sender == gig.contractor && _userToRate == gig.worker);
        require(isContractorRatingWorker, "GigTrust: Only the Contractor can rate the Worker.");

        require(!gig.contractorRatedWorker, "GigTrust: Contractor already rated the worker for this gig.");
        gig.contractorRatedWorker = true;
        
        // Apply the rating and calculate the new average reputation score
        User storage ratedUser = users[_userToRate];
        ratedUser.totalRating += _rating;
        ratedUser.reviewCount++;
        uint256 newReputationScore = ratedUser.totalRating / ratedUser.reviewCount;

        emit UserRated(msg.sender, _userToRate, _rating, newReputationScore);
    }

    // --- View Functions (Free to call, used for reading status) ---

    /**
     * @dev Calculates the average reputation score for a user.
     */
    function getUserReputation(address _user) public view returns (uint256) {
        User storage u = users[_user];
        if (u.reviewCount == 0) {
            return 0;
        }
        return u.totalRating / u.reviewCount;
    }

    /**
     * @dev Retrieves the current status of a gig.
     */
    function getGigStatus(uint256 _gigId) public view returns (GigStatus) {
        return gigs[_gigId].status;
    }
}
