#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>

// ==========================================
// 1. 数据模型定义：统一存储抓取到的成员信息
// ==========================================
@interface HOMemberModel : NSObject
@property (nonatomic, copy) NSString *userId;
@property (nonatomic, copy) NSString *nickname;
@property (nonatomic, copy) NSString *avatarUrl;
@property (nonatomic, copy) NSString *groupId;
@property (nonatomic, copy) NSString *sourceType; // @"rank" 或 @"group"
@property (nonatomic, assign) BOOL isNew;         // 标记是否为新进人员
@end

@implementation HOMemberModel
@end

// ==========================================
// 2. 插件核心管理器（单例 + 悬浮窗 UI + 自动化逻辑）
// ==========================================
@interface HOPluginManager : NSObject <UITableViewDelegate, UITableViewDataSource>
@property (nonatomic, strong) UIWindow *floatWindow;
@property (nonatomic, strong) UIView *mainPanel;
@property (nonatomic, strong) UITableView *tableView;
@property (nonatomic, strong) UISegmentedControl *tabControl;
@property (nonatomic, strong) UILabel *statusLabel;

@property (nonatomic, strong) NSMutableArray<HOMemberModel *> *rankList;
@property (nonatomic, strong) NSMutableSet<NSString *> *rankIdSet;

@property (nonatomic, strong) NSMutableArray<HOMemberModel *> *groupMemberList;
@property (nonatomic, strong) NSMutableSet<NSString *> *groupMemberIdSet;
@property (nonatomic, strong) NSMutableArray<NSDictionary *> *groupList; // 存储抓取到的群聊列表
@property (nonatomic, copy) NSString *currentGroupId;

@property (nonatomic, strong) NSTimer *autoRefreshTimer;
@property (nonatomic, assign) BOOL isAutoRefreshing;

// 保存截获的原生控制器弱引用，用于触发自动化刷新
@property (nonatomic, weak) UIViewController *rankVC;
@property (nonatomic, weak) UIViewController *groupVC;

+ (instancetype)shared;
- (void)setupUI;
- (void)parseInterceptedJSON:(id)jsonObj;
- (void)openNativeUserProfileWithModel:(HOMemberModel *)model;
@end

@implementation HOPluginManager

+ (instancetype)shared {
    static HOPluginManager *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[HOPluginManager alloc] init];
        instance.rankList = [NSMutableArray array];
        instance.rankIdSet = [NSMutableSet set];
        instance.groupMemberList = [NSMutableArray array];
        instance.groupMemberIdSet = [NSMutableSet set];
        instance.groupList = [NSMutableArray array];
    });
    return instance;
}

// 初始化悬浮球和控制面板
- (void)setupUI {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self.floatWindow) return;
        
        // 1. 悬浮按钮窗口
        UIWindow *window = [[UIApplication sharedApplication].windows firstObject];
        if (!window) return;
        
        UIButton *floatBtn = [UIButton buttonWithType:UIButtonTypeCustom];
        floatBtn.frame = CGRectMake(window.bounds.size.width - 70, 150, 55, 55);
        floatBtn.backgroundColor = [[UIColor systemBlueColor] colorWithAlphaComponent:0.85];
        [floatBtn setTitle:@"海鸥\n助手" forState:UIControlStateNormal];
        floatBtn.titleLabel.numberOfLines = 2;
        floatBtn.titleLabel.font = [UIFont boldSystemFontOfSize:13];
        floatBtn.layer.cornerRadius = 27.5;
        floatBtn.layer.zPosition = 9999;
        [floatBtn addTarget:self action:@selector(togglePanel) forControlEvents:UIControlEventTouchUpInside];
        
        // 添加拖拽手势
        UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(handlePan:)];
        [floatBtn addGestureRecognizer:pan];
        [window addSubview:floatBtn];
        
        // 2. 主控制面板
        CGFloat panelW = window.bounds.size.width - 40;
        CGFloat panelH = window.bounds.size.height * 0.7;
        self.mainPanel = [[UIView alloc] initWithFrame:CGRectMake(20, (window.bounds.size.height - panelH)/2, panelW, panelH)];
        self.mainPanel.backgroundColor = [UIColor colorWithWhite:0.1 alpha:0.95];
        self.mainPanel.layer.cornerRadius = 16;
        self.mainPanel.layer.borderWidth = 1;
        self.mainPanel.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.2].CGColor;
        self.mainPanel.layer.zPosition = 9998;
        self.mainPanel.hidden = YES;
        [window addSubview:self.mainPanel];
        
        // 顶部切换 Tab
        self.tabControl = [[UISegmentedControl alloc] initWithItems:@[@"排行榜监控(无限制)", @"群成员监控"]];
        self.tabControl.frame = CGRectMake(15, 15, panelW - 30, 32);
        self.tabControl.selectedSegmentIndex = 0;
        self.tabControl.backgroundColor = [UIColor darkGrayColor];
        [self.tabControl addTarget:self action:@selector(tabChanged) forControlEvents:UIControlEventValueChanged];
        [self.mainPanel addSubview:self.tabControl];
        
        // 工具栏按钮：选择群聊、手动刷新、自动监控开关、侦测类名
        CGFloat btnW = (panelW - 45) / 4;
        NSArray *titles = @[@"选择群聊", @"立即刷新", @"自动:关", @"类名侦测"];
        SEL selectors[] = {@selector(selectGroup), @selector(manualRefresh), @selector(toggleAutoRefresh:), @selector(dumpCurrentVC)};
        
        for (int i = 0; i < 4; i++) {
            UIButton *btn = [UIButton buttonWithType:UIButtonTypeSystem];
            btn.frame = CGRectMake(15 + i * (btnW + 5), 55, btnW, 30);
            btn.backgroundColor = [UIColor colorWithWhite:0.25 alpha:1.0];
            [btn setTitle:titles[i] forState:UIControlStateNormal];
            [btn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
            btn.titleLabel.font = [UIFont systemFontOfSize:12];
            btn.layer.cornerRadius = 6;
            [btn addTarget:self action:selectors[i] forControlEvents:UIControlEventTouchUpInside];
            [self.mainPanel addSubview:btn];
        }
        
        // 状态栏
        self.statusLabel = [[UILabel alloc] initWithFrame:CGRectMake(15, 90, panelW - 30, 20)];
        self.statusLabel.textColor = [UIColor systemGreenColor];
        self.statusLabel.font = [UIFont systemFontOfSize:11];
        self.statusLabel.text = @"状态：等待数据截获... (请在App内点一次排行或群聊)";
        [self.mainPanel addSubview:self.statusLabel];
        
        // 列表视图
        self.tableView = [[UITableView alloc] initWithFrame:CGRectMake(10, 115, panelW - 20, panelH - 125) style:UITableViewStylePlain];
        self.tableView.backgroundColor = [UIColor clearColor];
        self.tableView.delegate = self;
        self.tableView.dataSource = self;
        self.tableView.rowHeight = 56;
        [self.mainPanel addSubview:self.tableView];
    });
}

- (void)handlePan:(UIPanGestureRecognizer *)recognizer {
    CGPoint translation = [recognizer translationInView:recognizer.view.superview];
    recognizer.view.center = CGPointMake(recognizer.view.center.x + translation.x, recognizer.view.center.y + translation.y);
    [recognizer setTranslation:CGPointZero inView:recognizer.view.superview];
}

- (void)togglePanel {
    self.mainPanel.hidden = !self.mainPanel.hidden;
    if (!self.mainPanel.hidden) {
        [self.tableView reloadData];
    }
}

- (void)tabChanged {
    [self.tableView reloadData];
}

// ==========================================
// 3. 解析底层截获的明文 JSON 数据
// ==========================================
- (void)parseInterceptedJSON:(id)jsonObj {
    if (![jsonObj isKindOfClass:[NSDictionary class]] && ![jsonObj isKindOfClass:[NSArray class]]) return;
    
    // 将数据统一转换为数组进行分析
    NSArray *candidateArray = nil;
    if ([jsonObj isKindOfClass:[NSArray class]]) {
        candidateArray = (NSArray *)jsonObj;
    } else if ([jsonObj isKindOfClass:[NSDictionary class]]) {
        NSDictionary *dict = (NSDictionary *)jsonObj;
        // 常见列表字段兜底探测
        for (NSString *key in @[@"list", @"rows", @"records", @"members", @"users", @"data", @"items"]) {
            if ([dict[key] isKindOfClass:[NSArray class]]) {
                candidateArray = dict[key];
                break;
            }
        }
    }
    
    if (!candidateArray || candidateArray.count == 0) return;
    id firstItem = [candidateArray firstObject];
    if (![firstItem isKindOfClass:[NSDictionary class]]) return;
    NSDictionary *sample = (NSDictionary *)firstItem;
    
    // A. 判断是否为【群聊列表】数据 (含 groupId / chatId 及群名)
    if ((sample[@"groupId"] || sample[@"chatId"]) && (sample[@"groupName"] || sample[@"name"]) && !sample[@"userId"]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self.groupList removeAllObjects];
            [self.groupList addObjectsFromArray:candidateArray];
            self.statusLabel.text = [NSString stringWithFormat:@"已捕获 %lu 个群聊，可点击[选择群聊]", (unsigned long)self.groupList.count];
        });
        return;
    }
    
    // B. 判断是否为【人员信息】(排行榜或群成员，包含头像与ID)
    BOOL hasUserKey = (sample[@"userId"] != nil || sample[@"id"] != nil || sample[@"uid"] != nil);
    BOOL hasAvatarKey = (sample[@"portrait"] != nil || sample[@"avatar"] != nil || sample[@"headImg"] != nil || sample[@"icon"] != nil);
    
    if (hasUserKey && hasAvatarKey) {
        BOOL isGroupData = (sample[@"groupId"] != nil || sample[@"role"] != nil || sample[@"joinTime"] != nil);
        
        dispatch_async(dispatch_get_main_queue(), ^{
            int newCount = 0;
            for (NSDictionary *item in candidateArray) {
                if (![item isKindOfClass:[NSDictionary class]]) continue;
                
                NSString *uid = [NSString stringWithFormat:@"%@", item[@"userId"] ?: (item[@"id"] ?: item[@"uid"])];
                NSString *name = [NSString stringWithFormat:@"%@", item[@"nickname"] ?: (item[@"name"] ?: (item[@"username"] ?: @"未知用户"))];
                NSString *avatar = [NSString stringWithFormat:@"%@", item[@"portrait"] ?: (item[@"avatar"] ?: item[@"headImg"])];
                if (![avatar hasPrefix:@"http"]) {
                    avatar = [NSString stringWithFormat:@"https://zd.oss.haiouchat.com/%@", avatar];
                }
                
                HOMemberModel *model = [[HOMemberModel alloc] init];
                model.userId = uid;
                model.nickname = name;
                model.avatarUrl = avatar;
                
                if (isGroupData) {
                    model.groupId = [NSString stringWithFormat:@"%@", item[@"groupId"] ?: self.currentGroupId ?: @""];
                    model.sourceType = @"group";
                    if (![self.groupMemberIdSet containsObject:uid]) {
                        model.isNew = (self.groupMemberList.count > 0); // 首次加载不标新，后续刷新进来的标新
                        [self.groupMemberIdSet addObject:uid];
                        [self.groupMemberList insertObject:model atIndex:0]; // 新人置顶
                        newCount++;
                    }
                } else {
                    model.sourceType = @"rank";
                    if (![self.rankIdSet containsObject:uid]) {
                        model.isNew = (self.rankList.count > 0);
                        [self.rankIdSet addObject:uid];
                        [self.rankList addObject:model];
                        newCount++;
                    }
                }
            }
            
            self.statusLabel.text = [NSString stringWithFormat:@"更新完成！新增 %d 人 | 榜:%lu 群:%lu", newCount, (unsigned long)self.rankList.count, (unsigned long)self.groupMemberList.count];
            [self.tableView reloadData];
        });
    }
}

// ==========================================
// 4. 群聊选择与自动化刷新控制
// ==========================================
- (void)selectGroup {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"选择目标群聊" message:@"请先在App群聊列表下拉刷新一次以捕获群数据，或直接输入GroupId" preferredStyle:UIAlertControllerStyleAlert];
    
    [alert addTextFieldWithConfigurationHandler:^(UITextField * _Nonnull textField) {
        textField.placeholder = @"手动输入 groupId (如 174601489745622282)";
        textField.text = self.currentGroupId ?: @"174601489745622282";
    }];
    
    for (NSDictionary *g in self.groupList) {
        NSString *gName = g[@"groupName"] ?: (g[@"name"] ?: @"未命名群");
        NSString *gId = [NSString stringWithFormat:@"%@", g[@"groupId"] ?: g[@"id"]];
        [alert addAction:[UIAlertAction actionWithTitle:[NSString stringWithFormat:@"%@ (%@)", gName, gId] style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
            self.currentGroupId = gId;
            [self.groupMemberList removeAllObjects];
            [self.groupMemberIdSet removeAllObjects];
            self.statusLabel.text = [NSString stringWithFormat:@"已锁定群: %@", gName];
            [self manualRefresh];
        }]];
    }
    
    [alert addAction:[UIAlertAction actionWithTitle:@"确定使用输入框ID" style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
        NSString *inputId = alert.textFields.firstObject.text;
        if (inputId.length > 0) {
            self.currentGroupId = inputId;
            [self.groupMemberList removeAllObjects];
            [self.groupMemberIdSet removeAllObjects];
            self.statusLabel.text = [NSString stringWithFormat:@"已锁定群ID: %@", inputId];
            [self manualRefresh];
        }
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    
    [[self topViewController] presentViewController:alert animated:YES completion:nil];
}

- (void)manualRefresh {
    self.statusLabel.text = @"正在触发原生网络刷新...";
    UIViewController *topVC = [self topViewController];
    
    // 自动寻找当前控制器或已缓存控制器的刷新方法并调用
    NSArray *refreshSelectors = @[@"loadData", @"refreshData", @"requestData", @"fetchData", @"headerRefresh", @" loadMoreData", @"requestMemberList"];
    for (NSString *selStr in refreshSelectors) {
        SEL sel = NSSelectorFromString(selStr);
        if ([topVC respondsToSelector:sel]) {
            ((void (*)(id, SEL))objc_msgSend)(topVC, sel);
            return;
        }
    }
    
    // 如果当前页面包含 UITableView 且配有 mj_header (iOS 最常用的下拉刷新库)
    for (UIView *subview in topVC.view.subviews) {
        if ([subview isKindOfClass:[UIScrollView class]]) {
            UIScrollView *scrollView = (UIScrollView *)subview;
            SEL mjHeaderSel = NSSelectorFromString(@"mj_header");
            if ([scrollView respondsToSelector:mjHeaderSel]) {
                id header = ((id (*)(id, SEL))objc_msgSend)(scrollView, mjHeaderSel);
                SEL beginSel = NSSelectorFromString(@"beginRefreshing");
                if (header && [header respondsToSelector:beginSel]) {
                    ((void (*)(id, SEL))objc_msgSend)(header, beginSel);
                    self.statusLabel.text = @"已触发 MJRefresh 自动拉取！";
                    return;
                }
            }
        }
    }
    self.statusLabel.text = @"提示：请保持在群成员或排行榜页面以激活自动刷新";
}

- (void)toggleAutoRefresh:(UIButton *)sender {
    self.isAutoRefreshing = !self.isAutoRefreshing;
    if (self.isAutoRefreshing) {
        [sender setTitle:@"自动:开" forState:UIControlStateNormal];
        sender.backgroundColor = [UIColor systemGreenColor];
        // 重要：根据日志 报错“手速太快,请稍后再试”，间隔设为 5.0 秒最为稳妥！
        self.autoRefreshTimer = [NSTimer scheduledTimerWithTimeInterval:5.0 target:self selector:@selector(manualRefresh) userInfo:nil repeats:YES];
    } else {
        [sender setTitle:@"自动:关" forState:UIControlStateNormal];
        sender.backgroundColor = [UIColor colorWithWhite:0.25 alpha:1.0];
        [self.autoRefreshTimer invalidate];
        self.autoRefreshTimer = nil;
    }
}

// ==========================================
// 5. 最核心环节：点击成员弹出原生个人添加好友页
// ==========================================
- (void)openNativeUserProfileWithModel:(HOMemberModel *)model {
    // 隐藏插件面板，漏出底层原生界面
    self.mainPanel.hidden = YES;
    
    UIViewController *topVC = [self topViewController];
    UINavigationController *nav = topVC.navigationController;
    if (!nav && [topVC isKindOfClass:[UINavigationController class]]) {
        nav = (UINavigationController *)topVC;
    }
    
    // 方案 A：遍历 Runtime 中所有 ViewController，匹配海鸥个人主页控制器 (Swift 类名通常带有 Module 前缀，如 ZhengDu.UserDetailViewController)
    int numClasses = objc_getClassList(NULL, 0);
    Class *classes = (__unsafe_unretained Class *)malloc(sizeof(Class) * numClasses);
    numClasses = objc_getClassList(classes, numClasses);
    
    Class targetClass = nil;
    for (int i = 0; i < numClasses; i++) {
        NSString *className = NSStringFromClass(classes[i]);
        // 查找海鸥内部包含 UserInfo / UserDetail / PersonalCard / Stranger 等特征的 ViewController
        if (([className containsString:@"ZhengDu"] || [className containsString:@"HaiOu"] || [className containsString:@"HO"]) &&
            ([className containsString:@"UserDetail"] || [className containsString:@"UserInfo"] || [className containsString:@"Person"] || [className containsString:@"Profile"] || [className containsString:@"ContactDetail"]) &&
            [classes[i] isSubclassOfClass:[UIViewController class]]) {
            targetClass = classes[i];
            break;
        }
    }
    free(classes);
    
    if (targetClass && nav) {
        @try {
            UIViewController *profileVC = [[targetClass alloc] init];
            // 利用 KVC 动态尝试注入 userId / targetId / id / groupId（根据抓包日志 2 的参数名）
            NSArray *idKeys = @[@"userId", @"targetId", @"otherId", @"uid", @"id", @"memberId"];
            for (NSString *key in idKeys) {
                @try {
                    [profileVC setValue:model.userId forKey:key];
                } @catch (NSException *e) {}
            }
            if (model.groupId.length > 0) {
                @try {
                    [profileVC setValue:model.groupId forKey:@"groupId"];
                } @catch (NSException *e) {}
            }
            
            [nav pushViewController:profileVC animated:YES];
            return;
        } @catch (NSException *exception) {
            NSLog(@"[HOPlugin] Push 异常: %@", exception);
        }
    }
    
    // 方案 B（保底引导）：如果类名混淆，弹窗提示用户使用右上角【类名侦测】自动定位
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"跳转准备就绪"
                                                                   message:[NSString stringWithFormat:@"已锁定目标：%@\nID：%@\n\n请先在App中手动点开任意一个人的【添加好友资料页】，然后点插件上的【类名侦测】按钮绑定一次页面类名即可全自动跳转！", model.nickname, model.userId]
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"复制该用户ID" style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
        [UIPasteboard generalPasteboard].string = model.userId;
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"知道了" style:UIAlertActionStyleCancel handler:nil]];
    [topVC presentViewController:alert animated:YES completion:nil];
}

// 辅助功能：一键侦测当前打开的控制器类名及属性名（解决 Swift 类名混淆）
- (void)dumpCurrentVC {
    UIViewController *topVC = [self topViewController];
    NSString *className = NSStringFromClass([topVC class]);
    
    unsigned int count = 0;
    Ivar *ivars = class_copyIvarList([topVC class], &count);
    NSMutableString *ivarStr = [NSMutableString string];
    for (int i = 0; i < count; i++) {
        [ivarStr appendFormat:@"%s\n", ivar_getName(ivars[i])];
    }
    free(ivars);
    
    // 自动记录该类名到本地，供下次点击成员时直接调用
    [[NSUserDefaults standardUserDefaults] setObject:className forKey:@"HO_SavedProfileVCClass"];
    
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"当前页面侦测成功"
                                                                   message:[NSString stringWithFormat:@"类名:\n%@\n\n内部属性:\n%@", className, ivarStr]
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"复制信息并绑定为加好友页" style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
        [UIPasteboard generalPasteboard].string = [NSString stringWithFormat:@"Class: %@\nIvars:\n%@", className, ivarStr];
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"关闭" style:UIAlertActionStyleCancel handler:nil]];
    [topVC presentViewController:alert animated:YES completion:nil];
}

- (UIViewController *)topViewController {
    UIViewController *resultVC = [[[UIApplication sharedApplication].windows firstObject] rootViewController];
    while (resultVC.presentedViewController) {
        resultVC = resultVC.presentedViewController;
    }
    if ([resultVC isKindOfClass:[UITabBarController class]]) {
        resultVC = [(UITabBarController *)resultVC selectedViewController];
    }
    if ([resultVC isKindOfClass:[UINavigationController class]]) {
        resultVC = [(UINavigationController *)resultVC topViewController];
    }
    return resultVC;
}

// ==========================================
// 6. TableView 数据源与头像异步渲染
// ==========================================
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return (self.tabControl.selectedSegmentIndex == 0) ? self.rankList.count : self.groupMemberList.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    static NSString *cellId = @"HOMemberCell";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:cellId];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:cellId];
        cell.backgroundColor = [UIColor clearColor];
        cell.textLabel.textColor = [UIColor whiteColor];
        cell.detailTextLabel.textColor = [UIColor lightGrayColor];
        cell.imageView.layer.cornerRadius = 20;
        cell.imageView.layer.masksToBounds = YES;
    }
    
    NSArray *dataSource = (self.tabControl.selectedSegmentIndex == 0) ? self.rankList : self.groupMemberList;
    HOMemberModel *model = dataSource[indexPath.row];
    
    cell.textLabel.text = model.isNew ? [NSString stringWithFormat:@"🔥[新进] %@", model.nickname] : model.nickname;
    cell.textLabel.textColor = model.isNew ? [UIColor systemYellowColor] : [UIColor whiteColor];
    cell.detailTextLabel.text = [NSString stringWithFormat:@"ID: %@  (点击弹窗加好友)", model.userId];
    
    // 异步加载海鸥 OSS 头像 (https://zd.oss.haiouchat.com/...)
    cell.imageView.image = [UIImage new]; // 占位
    if (model.avatarUrl.length > 0) {
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            NSData *imgData = [NSData dataWithContentsOfURL:[NSURL URLWithString:model.avatarUrl]];
            if (imgData) {
                UIImage *img = [UIImage imageWithData:imgData];
                dispatch_async(dispatch_get_main_queue(), ^{
                    UITableViewCell *updateCell = [tableView cellForRowAtIndexPath:indexPath];
                    if (updateCell) {
                        updateCell.imageView.image = img;
                        [updateCell setNeedsLayout];
                    }
                });
            }
        });
    }
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    NSArray *dataSource = (self.tabControl.selectedSegmentIndex == 0) ? self.rankList : self.groupMemberList;
    HOMemberModel *model = dataSource[indexPath.row];
    model.isNew = NO; // 取消高亮
    [self openNativeUserProfileWithModel:model];
}

@end

// ==========================================
// 7. Hook 模块：网络改包突破限制 + 解密后数据截获
// ==========================================

%hook NSURLSession

// 拦截 Alamofire 发起的底层网络请求，自动篡改 limit 突破排行榜和群成员数量限制
- (NSURLSessionDataTask *)dataTaskWithRequest:(NSURLRequest *)request completionHandler:(void (^)(NSData * _Nullable, NSURLResponse * _Nullable, NSError * _Nullable))completionHandler {
    NSMutableURLRequest *mutableReq = [request mutableCopy];
    NSString *urlStr = mutableReq.URL.absoluteString;
    
    if ([urlStr containsString:@"api.haiouchat.com/api/sys/open"]) {
        // 匹配排行榜 (scene=1) 或 群成员/群列表请求中的 limit 参数
        if ([urlStr containsString:@"limit="]) {
            NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:@"limit=\\d+" options:0 error:nil];
            // 将原有的 limit=5 / limit=20 / limit=200 直接突破替换为 limit=1000
            NSString *modifiedUrlStr = [regex stringByReplacingMatchesInString:urlStr options:0 range:NSMakeRange(0, urlStr.length) withTemplate:@"limit=1000"];
            mutableReq.URL = [NSURL URLWithString:modifiedUrlStr];
        }
    }
    return %orig(mutableReq, completionHandler);
}

%end

%hook NSJSONSerialization

// 核心技巧：绕过 "FLmZB05S..." 密文算法，直接在 App 内部解密后调用 JSON 解析的瞬间截获明文字典！
+ (id)JSONObjectWithData:(NSData *)data options:(NSJSONReadingOptions)opt error:(NSError * _Nullable __autoreleasing *)error {
    id result = %orig(data, opt, error);
    if (result) {
        [[HOPluginManager shared] parseInterceptedJSON:result];
    }
    return result;
}

%end

%hook UIViewController

- (void)viewDidAppear:(BOOL)animated {
    %orig(animated);
    // 确保 App 启动进入主界面后自动挂载插件悬浮球
    [[HOPluginManager shared] setupUI];
}

%end
