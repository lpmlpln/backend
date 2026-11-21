import Foundation
import MealPlannerCore
import Vapor

extension UserDTO: Content {}
extension TokenPair: Content {}
extension MagicLinkRequest: Content {}
extension MagicLinkResponse: Content {}
extension AppleSignInRequest: Content {}
extension RefreshRequest: Content {}
extension DeviceRegistration: Content {}

extension RecipeDTO: Content {}
extension IngredientDTO: Content {}
extension RecipeImageDTO: Content {}
extension PersonalizationDTO: Content {}
extension RecipeCreateRequest: Content {}
extension RecipeImportRequest: Content {}
extension RecipeImportResponse: Content {}
extension ImportJobDTO: Content {}
extension PlanEntryUpdateRequest: Content {}
extension FriendRequestLike: Content {}
extension LockRequest: Content {}
extension FriendRequest: Content {}

struct RecipeListResponse: Content {
    var items: [RecipeDTO]
    var nextCursor: String?
}

extension PlanDTO: Content {}
extension PlanEntryDTO: Content {}
extension PlanMemberDTO: Content {}
extension PlanCreateRequest: Content {}
extension PlanUpdateRequest: Content {}
extension RecalculateRequest: Content {}
extension PlanMemberRequest: Content {}
extension ShoppingListDTO: Content {}
extension ShoppingItemDTO: Content {}
extension ShoppingCheckRequest: Content {}

extension FriendDTO: Content {}

extension SyncPullResponse: Content {}
extension SyncPushRequest: Content {}
extension SyncPushResponse: Content {}
extension APIErrorBody: Content {}
