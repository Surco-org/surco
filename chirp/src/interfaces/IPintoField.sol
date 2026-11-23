// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice Live Pinto field surface, from the diamond loupe.
///         sow takes (amount, minTemperature, mode). minTemperature is 1e6-scaled percent, not WAD.
///         sowWithReferral takes (amount, minTemperature, minSoil, mode, referrer) and returns
///         (pods, referrerPods, refereePods). An unusable referrer still sows and pays no bonus.
///         plot reads one plot. harvest takes a field id and a list of plot indexes.
interface IPintoField {
    function totalSoil() external view returns (uint256);

    function temperature() external view returns (uint256);

    /// @notice Cap, in the same 1e6-scaled percent as temperature(). Fork-confirmed on the diamond.
    function maxTemperature() external view returns (uint256);

    function activeField() external view returns (uint256);

    function podIndex(uint256 fieldId) external view returns (uint256);

    function harvestableIndex(uint256 fieldId) external view returns (uint256);

    function plot(address account, uint256 fieldId, uint256 index) external view returns (uint256);

    function sow(uint256 amount, uint256 minTemperature, uint8 mode) external returns (uint256 pods);

    function sowWithReferral(uint256 amount, uint256 minTemperature, uint256 minSoil, uint8 mode, address referrer)
        external
        returns (uint256 pods, uint256 referrerPods, uint256 refereePods);

    function harvest(uint256 fieldId, uint256[] calldata plots, uint8 mode) external returns (uint256 beans);
}
