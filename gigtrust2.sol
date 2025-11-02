// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * -------------------------------------------------------------------
 * @title ReentrancyGuard
 * @dev Minimal inline version to prevent reentrant calls.
 * -------------------------------------------------------------------
 */
abstract contract ReentrancyGuard {
    uint256 private constant _NOT_ENTERED = 1;
    uint256 private constant _ENTERED = 2;
    uint256 private _status;

    constructor() {
        _status = _NOT_ENTERED;
    }

    modifier nonReentrant() {
        require(_status != _ENTERED, "ReentrancyGuard: reentrant call");
        _status = _ENTERED;
        _;
        _status = _NOT_ENTERED;
    }
}

/**
 * -------------------------------------------------------------------
 * @title GigTrust
 * @notice A trust-based gig economy smart contract with escrow, rating,
 *         and reputation tracking. Ensures fair payments and reputation
 *         integrity using one-sided rating (Contractor → Worker).
 * -------------------------------------------------------------------
 */
contract GigTrust is ReentrancyGuard {
    // ----------------------------------------------------------
    // ENUMS
    // ----------------------------------------------------------

    enum UserRole {
        None,
        Contractor, // Posts gigs, pays, rates workers
        Worker      // Accepts gigs, receives pay
    }

    enum GigStatus {
        Open,
        Accepted,
        CompletedByWorker,
        ConfirmedByContractor,
        Paid,
        Cancelled
    }

    // ----------------------------------------------------------
    // STRUCTS
    // ----------------------------------------------------------

    struct User {
        UserRole role;
        uint256 totalRating;
        uint256 reviewCount;
    }

    struct Gig {
        uint256 id;
        address payable contractor;
        address payable worker;
        string description;
        uint256 fee;
        GigStatus status;
        bool contractorRatedWorker;
    }

    // ----------------------------------------------------------
    // STATE VARIABLES
    // ----------------------------------------------------------

    mapping(address => User) public users;
    mapping(uint256 => Gig) public gigs;
    uint256 public nextGigId = 1;

    // ----------------------------------------------------------
    // EVENTS
    // ----------------------------------------------------------

    event UserRegistered(address indexed userAddress, UserRole role);
    event GigCreated(uint256 indexed gigId, address indexed contractor, uint256 fee, string description);
    event GigAccepted(uint256 indexed gigId, address indexed worker);
    event GigCompleted(uint256 indexed gigId);
    event GigConfirmed(uint256 indexed gigId);
    event PaymentSent(uint256 indexed gigId, address indexed worker, uint256 amount);
    event GigCancelled(uint256 indexed gigId, address indexed contractor, uint256 refundAmount);
    event UserRated(address indexed rater, address indexed ratedUser, uint256 rating, uint256 newReputationScore);

    // ----------------------------------------------------------
    // MODIFIERS
    // ----------------------------------------------------------

    modifier onlyRole(UserRole _role) {
        require(users[msg.sender].role == _role, "GigTrust: Caller must have required role.");
        _;
    }

    modifier onlyGigExists(uint256 _gigId) {
        require(gigs[_gigId].id != 0, "GigTrust: Gig does not exist.");
        _;
    }

    modifier onlyGigParticipant(uint256 _gigId) {
        Gig storage gig = gigs[_gigId];
        require(msg.sender == gig.contractor || msg.sender == gig.worker, "GigTrust: Not a participant.");
        _;
    }

    // ----------------------------------------------------------
    // USER MANAGEMENT
    // ----------------------------------------------------------

    function registerUser(UserRole _role) external {
        require(users[msg.sender].role == UserRole.None, "GigTrust: Already registered.");
        require(_role == UserRole.Contractor || _role == UserRole.Worker, "GigTrust: Invalid role.");
        users[msg.sender].role = _role;
        emit UserRegistered(msg.sender, _role);
    }

    // ----------------------------------------------------------
    // GIG LIFECYCLE
    // ----------------------------------------------------------

    /**
     * @dev Contractor creates a gig and deposits ETH as escrow.
     */
    function createGig(string calldata _description, uint256 _fee)
        external
        payable
        onlyRole(UserRole.Contractor)
    {
        require(_fee > 0, "GigTrust: Fee must be > 0.");
        require(msg.value == _fee, "GigTrust: Value must match fee.");

        uint256 gigId = nextGigId++;
        gigs[gigId] = Gig({
            id: gigId,
            contractor: payable(msg.sender),
            worker: payable(address(0)),
            description: _description,
            fee: _fee,
            status: GigStatus.Open,
            contractorRatedWorker: false
        });

        emit GigCreated(gigId, msg.sender, _fee, _description);
    }

    /**
     * @dev Worker accepts an open gig.
     */
    function acceptGig(uint256 _gigId)
        external
        onlyRole(UserRole.Worker)
        onlyGigExists(_gigId)
    {
        Gig storage gig = gigs[_gigId];
        require(gig.status == GigStatus.Open, "GigTrust: Not open.");
        require(gig.contractor != msg.sender, "GigTrust: Cannot accept own gig.");

        gig.worker = payable(msg.sender);
        gig.status = GigStatus.Accepted;

        emit GigAccepted(_gigId, msg.sender);
    }

    /**
     * @dev Worker marks the gig as completed.
     */
    function completeGig(uint256 _gigId)
        external
        onlyRole(UserRole.Worker)
        onlyGigExists(_gigId)
    {
        Gig storage gig = gigs[_gigId];
        require(gig.status == GigStatus.Accepted, "GigTrust: Must be Accepted.");
        require(gig.worker == msg.sender, "GigTrust: Not your gig.");

        gig.status = GigStatus.CompletedByWorker;
        emit GigCompleted(_gigId);
    }

    /**
     * @dev Contractor confirms the gig and releases payment.
     */
    function confirmGigAndPay(uint256 _gigId)
        external
        nonReentrant
        onlyGigExists(_gigId)
    {
        Gig storage gig = gigs[_gigId];
        require(gig.status == GigStatus.CompletedByWorker, "GigTrust: Must be completed.");
        require(gig.contractor == msg.sender, "GigTrust: Only contractor can confirm.");

        uint256 amount = gig.fee;
        gig.fee = 0;
        gig.status = GigStatus.Paid;

        (bool success, ) = gig.worker.call{value: amount}("");
        require(success, "GigTrust: Payment failed.");

        emit PaymentSent(_gigId, gig.worker, amount);
    }

    /**
     * @dev Contractor can cancel gig before worker accepts it.
     * Refunds escrow safely.
     */
    function cancelGig(uint256 _gigId)
        external
        nonReentrant
        onlyRole(UserRole.Contractor)
        onlyGigExists(_gigId)
    {
        Gig storage gig = gigs[_gigId];
        require(gig.contractor == msg.sender, "GigTrust: Not your gig.");
        require(gig.status == GigStatus.Open, "GigTrust: Can cancel only if open.");

        uint256 refund = gig.fee;
        gig.fee = 0;
        gig.status = GigStatus.Cancelled;

        (bool success, ) = gig.contractor.call{value: refund}("");
        require(success, "GigTrust: Refund failed.");

        emit GigCancelled(_gigId, msg.sender, refund);
    }

    // ----------------------------------------------------------
    // RATING SYSTEM
    // ----------------------------------------------------------

    /**
     * @dev Contractor rates the worker after successful payment.
     */
    function rateUser(
        uint256 _gigId,
        address _userToRate,
        uint256 _rating
    )
        external
        onlyGigParticipant(_gigId)
        onlyGigExists(_gigId)
    {
        Gig storage gig = gigs[_gigId];
        require(gig.status == GigStatus.Paid, "GigTrust: Only after payment.");
        require(_rating >= 1 && _rating <= 5, "GigTrust: Rating 1-5 only.");
        require(msg.sender == gig.contractor, "GigTrust: Only contractor rates.");
        require(_userToRate == gig.worker, "GigTrust: Must rate worker.");
        require(!gig.contractorRatedWorker, "GigTrust: Already rated.");

        gig.contractorRatedWorker = true;

        User storage worker = users[_userToRate];
        worker.totalRating += _rating;
        worker.reviewCount++;
        uint256 newScore = worker.totalRating / worker.reviewCount;

        emit UserRated(msg.sender, _userToRate, _rating, newScore);
    }

    // ----------------------------------------------------------
    // VIEW FUNCTIONS
    // ----------------------------------------------------------

    function getUserReputation(address _user) external view returns (uint256) {
        User storage u = users[_user];
        if (u.reviewCount == 0) return 0;
        return u.totalRating / u.reviewCount;
    }

    function getGigStatus(uint256 _gigId) external view onlyGigExists(_gigId) returns (GigStatus) {
        return gigs[_gigId].status;
    }

    function getGigDetails(uint256 _gigId)
        external
        view
        onlyGigExists(_gigId)
        returns (
            address contractor,
            address worker,
            string memory description,
            uint256 fee,
            GigStatus status
        )
    {
        Gig storage gig = gigs[_gigId];
        return (gig.contractor, gig.worker, gig.description, gig.fee, gig.status);
    }
}
